{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cooked.MockChain.Monad.Direct where

import qualified Cardano.Api.Shelley as C
import Control.Applicative
import Control.Lens hiding (ix)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import Cooked.MockChain.Monad
import Cooked.MockChain.UtxoPredicate
import Cooked.MockChain.UtxoState
import Cooked.MockChain.Wallet
import Cooked.Tx.Balance
import Cooked.Tx.Constraints
import Data.Bifunctor (Bifunctor (first, second))
import Data.Default
import Data.Foldable (asum)
import Data.Function (on)
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, mapMaybe)
import qualified Data.Set as S
import Data.Void
import qualified Ledger as Pl
import qualified Ledger.Ada as Ada
import qualified Ledger.Constraints as Pl
import qualified Ledger.Constraints.OffChain as Pl
import qualified Ledger.Credential as Pl
import qualified Ledger.Fee as Pl
import Ledger.Orphans () 
import qualified Ledger.TimeSlot as Pl
import qualified Ledger.Tx.CardanoAPI.Internal as Pl
import qualified Ledger.Validation as Pl
import qualified Ledger.Value as Pl
import qualified Plutus.V1.Ledger.Api as PV1
import qualified PlutusTx as Pl
import qualified PlutusTx.Lattice as PlutusTx
import qualified PlutusTx.Numeric as Pl
import qualified PlutusTx.Ratio as R
import qualified Wallet.Emulator.Chain as Em

-- * Direct Emulation

-- $mockchaindocstr
--
-- The MockChainT monad provides a direct emulator; that is, it gives us a simple way to call
-- validator scripts directly, without the need for all the complexity the 'Contract'
-- monad introduces.
--
-- Running a 'MockChain' produces a 'UtxoState', which is a map from 'Pl.Address' to
-- @(Pl.Value, Maybe Pl.Datum)@, and corresponds to the utxo mental model most people have.
-- Internally, however, we keep a 'Pl.UtxoIndex' in our state and feeding it to 'Pl.validateTx'.
-- For convenience, we also keep a map of 'Pl.Address' to 'Pl.Datum', giving is a simple
-- way of managing the current utxo state.

mcstToUtxoState :: MockChainSt -> UtxoState
mcstToUtxoState s =
  UtxoState . M.fromListWith (<>) . map (uncurry go1) . M.toList . Pl.getIndex . mcstIndex $ s
  where
    go1 :: Pl.TxOutRef -> Pl.TxOut -> (Pl.Address, UtxoValueSet)
    go1 _ (Pl.fromCardanoTxOutToPV1TxInfoTxOut . Pl.getTxOut -> PV1.TxOut addr val mdh) = do
      (addr, UtxoValueSet [(val, mdh >>= go2)])

    go2 :: Pl.DatumHash -> Maybe UtxoDatum
    go2 datumHash = do
      datumStr <- M.lookup datumHash (mcstStrDatums s)
      datum <- M.lookup datumHash (mcstDatums s)
      return $ UtxoDatum datum datumStr

-- | Slightly more concrete version of 'UtxoState', used to actually run the simulation.
--  We keep a map from datum hash to datum, then a map from txOutRef to datumhash
--  Additionally, we also keep a map from datum hash to the underlying value's "show" result,
--  in order to display the contents of the state to the user.
data MockChainSt = MockChainSt
  { mcstIndex :: Pl.UtxoIndex,
    mcstDatums :: M.Map Pl.DatumHash Pl.Datum,
    mcstStrDatums :: M.Map Pl.DatumHash String,
    mcstCurrentSlot :: Pl.Slot
  }
  deriving (Show, Eq)

instance Default Pl.Slot where
  def = Pl.Slot 0

-- | The errors that can be produced by the 'MockChainT' monad
data MockChainError
  = MCEValidationError Pl.ValidationErrorInPhase
  | MCETxError Pl.MkTxError
  | MCEUnbalanceable BalanceStage Pl.Tx BalanceTxRes
  | MCENoSuitableCollateral
  | FailWith String
  deriving (Show, Eq)

-- | Describes us which stage of the balancing process are we at. This is needed
--  to distinguish the successive calls to balancing while computing fees from
--  the final call to balancing
data BalanceStage
  = BalCalcFee
  | BalFinalizing
  deriving (Show, Eq)

data MockChainEnv = MockChainEnv
  { mceParams :: Pl.Params,
    mceSigners :: NE.NonEmpty Wallet
  }
  deriving (Show)

instance Default MockChainEnv where
  def = MockChainEnv def (wallet 1 NE.:| [])

-- | The actual 'MockChainT' is a trivial combination of 'StateT' and 'ExceptT'
newtype MockChainT m a = MockChainT
  {unMockChain :: ReaderT MockChainEnv (StateT MockChainSt (ExceptT MockChainError m)) a}
  deriving newtype (Functor, Applicative, MonadState MockChainSt, MonadError MockChainError, MonadReader MockChainEnv)

-- | Non-transformer variant
type MockChain = MockChainT Identity

-- Custom monad instance made to increase the slot count automatically
instance (Monad m) => Monad (MockChainT m) where
  return = pure
  MockChainT x >>= f = MockChainT $ x >>= unMockChain . f

instance (Monad m) => MonadFail (MockChainT m) where
  fail = throwError . FailWith

instance MonadTrans MockChainT where
  lift = MockChainT . lift . lift . lift

instance (Monad m, Alternative m) => Alternative (MockChainT m) where
  empty = MockChainT $ ReaderT $ const $ StateT $ const $ ExceptT empty
  (<|>) = combineMockChainT (<|>)

combineMockChainT ::
  (Monad m) =>
  (forall a. m a -> m a -> m a) ->
  MockChainT m x ->
  MockChainT m x ->
  MockChainT m x
combineMockChainT f ma mb = MockChainT $
  ReaderT $ \r ->
    StateT $ \s ->
      let resA = runExceptT $ runStateT (runReaderT (unMockChain ma) r) s
          resB = runExceptT $ runStateT (runReaderT (unMockChain mb) r) s
       in ExceptT $ f resA resB

mapMockChainT ::
  (m (Either MockChainError (a, MockChainSt)) -> n (Either MockChainError (b, MockChainSt))) ->
  MockChainT m a ->
  MockChainT n b
mapMockChainT f = MockChainT . mapReaderT (mapStateT (mapExceptT f)) . unMockChain

-- | Executes a 'MockChainT' from some initial state and environment; does /not/
-- convert the 'MockChainSt' into a 'UtxoState'.
runMockChainTRaw ::
  (Monad m) =>
  MockChainEnv ->
  MockChainSt ->
  MockChainT m a ->
  m (Either MockChainError (a, MockChainSt))
runMockChainTRaw e0 i0 =
  runExceptT
    . flip runStateT i0
    . flip runReaderT e0
    . unMockChain

-- | Executes a 'MockChainT' from an initial state set up with the given initial value distribution.
-- Similar to 'runMockChainT', uses the default environment. Returns a 'UtxoState' instead of
-- a 'MockChainSt'. If you need the later, use 'runMockChainTRaw'
runMockChainTFrom ::
  (Monad m) =>
  InitialDistribution ->
  MockChainT m a ->
  m (Either MockChainError (a, UtxoState))
runMockChainTFrom i0 =
  fmap (fmap $ second mcstToUtxoState) . runMockChainTRaw def (mockChainSt0From (mceParams def) i0)

-- | Executes a 'MockChainT' from the canonical initial state and environment. The canonical
--  environment uses the default 'SlotConfig' and @[Cooked.MockChain.Wallet.wallet 1]@ as the sole
--  wallet signing transactions.
runMockChainT :: (Monad m) => MockChainT m a -> m (Either MockChainError (a, UtxoState))
runMockChainT = runMockChainTFrom def

-- | See 'runMockChainTRaw'
runMockChainRaw :: MockChainEnv -> MockChainSt -> MockChain a -> Either MockChainError (a, MockChainSt)
runMockChainRaw e0 i0 = runIdentity . runMockChainTRaw e0 i0

-- | See 'runMockChainTFrom'
runMockChainFrom ::
  InitialDistribution -> MockChain a -> Either MockChainError (a, UtxoState)
runMockChainFrom i0 = runIdentity . runMockChainTFrom i0

-- | See 'runMockChainT'
runMockChain :: MockChain a -> Either MockChainError (a, UtxoState)
runMockChain = runIdentity . runMockChainT

-- Canonical initial values

utxoState0 :: UtxoState
utxoState0 = mcstToUtxoState mockChainSt0

mockChainSt0 :: MockChainSt
mockChainSt0 = MockChainSt (utxoIndex0 def) M.empty M.empty def

mockChainSt0From :: Pl.Params -> InitialDistribution -> MockChainSt
mockChainSt0From lparams i0 = MockChainSt (utxoIndex0From lparams i0) M.empty M.empty def

instance Default MockChainSt where
  def = mockChainSt0

utxoIndex0From :: Pl.Params -> InitialDistribution -> Pl.UtxoIndex
utxoIndex0From lparams i0 = Pl.initialise [[Pl.Valid $ Pl.EmulatorTx $ initialTxFor lparams i0]]

utxoIndex0 :: Pl.Params -> Pl.UtxoIndex
utxoIndex0 lparams = utxoIndex0From lparams def

-- ** Direct Interpretation of Operations

instance (Monad m) => MonadBlockChain (MockChainT m) where
  validateTxSkel lparams skel = do
    tx <- Pl.EmulatorTx <$> generateTx' skel
    _ <- validateTx lparams tx
    when (autoSlotIncrease $ txOpts skel) $ modify' (\st -> st {mcstCurrentSlot = mcstCurrentSlot st + 1})
    return tx

  validateTx = validateTx'

  txOutByRef _lparams outref = gets (M.lookup outref . Pl.getIndex . mcstIndex)

  ownPaymentPubKeyHash = asks (walletPKHash . NE.head . mceSigners)

  utxosSuchThat = utxosSuchThat'

  datumFromTxOut Pl.PublicKeyChainIndexTxOut {} = pure Nothing
  datumFromTxOut (Pl.ScriptChainIndexTxOut _ _ (_, Just d) _ _) = pure $ Just d
  -- datum is always present in the nominal case, guaranteed by chain-index
  datumFromTxOut (Pl.ScriptChainIndexTxOut _ _ (dh, Nothing) _ _) =
    M.lookup dh <$> gets mcstDatums

  currentSlot = gets mcstCurrentSlot

  currentTime = asks (Pl.slotToEndPOSIXTime . Pl.pSlotConfig . mceParams) <*> gets mcstCurrentSlot

  awaitSlot s = modify' (\st -> st {mcstCurrentSlot = max s (mcstCurrentSlot st)}) >> currentSlot

  awaitTime t = do
    sc <- slotConfig
    s <- awaitSlot (1 + Pl.posixTimeToEnclosingSlot sc t)
    return $ Pl.slotToBeginPOSIXTime sc s

instance (Monad m) => MonadMockChain (MockChainT m) where
  signingWith ws = local $ \env -> env {mceSigners = ws}

  askSigners = asks mceSigners

  params = asks mceParams

  localParams f = local (\e -> e {mceParams = f (mceParams e)})

-- | This validates a given 'Pl.Tx' in its proper context; this is a very tricky thing to do. We're basing
--  ourselves off from how /plutus-apps/ is doing it.
--
--  TL;DR: we need to use "Ledger.Index" to compute the new 'Pl.UtxoIndex', but we neet to
--  rely on "Ledger.Validation" to run the validation akin to how it happens on-chain, with
--  proper checks on transactions fees and signatures.
--
--  For more details, check the following relevant pointers:
--
--  1. https://github.com/tweag/plutus-libs/issues/92
--  2. https://github.com/input-output-hk/plutus-apps/blob/03ba6b7e8b9371adf352ffd53df8170633b6dffa/plutus-ledger/src/Ledger/Tx.hs#L126
--  3. https://github.com/input-output-hk/plutus-apps/blob/03ba6b7e8b9371adf352ffd53df8170633b6dffa/plutus-contract/src/Wallet/Emulator/Chain.hs#L209
--  4. https://github.com/input-output-hk/plutus-apps/blob/03ba6b7e8b9371adf352ffd53df8170633b6dffa/plutus-contract/src/Wallet/Emulator/Wallet.hs#L314
--
-- Finally; because 'Pl.fromPlutusTx' doesn't preserve signatures, we need the list of signers
-- around to re-sign the transaction.
runTransactionValidation ::
  Pl.Slot ->
  Pl.Params ->
  Pl.UtxoIndex ->
  [Pl.PaymentPubKeyHash] ->
  [Wallet] ->
  Pl.Tx ->
  (Pl.UtxoIndex, Pl.CardanoTx, Maybe Pl.ValidationErrorInPhase)
runTransactionValidation s lparams ix reqSigs signers tx =
  let !cIndex = either (error . show) id $ Pl.fromPlutusIndex ix
      cardanoTx = either (error . show) id $ Pl.fromPlutusTx lparams cIndex reqSigs tx
      !ctx' = L.foldl' (flip txAddSignatureAPI) (Pl.CardanoApiTx (Pl.CardanoApiEmulatorEraTx cardanoTx)) signers
      e = Pl.validateCardanoTx lparams s cIndex ctx'
      -- Now we compute the new index
      ix' = case e of
        Just (Pl.Phase1, _) -> ix
        Just (Pl.Phase2, _) -> Pl.insertCollateral ctx' ix
        Nothing -> Pl.insert ctx' ix
   in (ix', ctx', e)

-- | Check 'validateTx' for details; we pass the list of required signatories since
-- that is only truly available from the unbalanced tx, so we bubble that up all the way here.
validateTx' :: (Monad m) => Pl.Params ->  Pl.CardanoTx -> MockChainT m Pl.TxId
validateTx' lparams tx = do
  s <- currentSlot
  ix <- gets mcstIndex
  ps <- asks mceParams
  let ctx = Em.ValidationCtx ix ps
      (status, Em.ValidationCtx ix' _) = runState (Em.validateEm s tx) ctx
  case status of
    Just err -> throwError (MCEValidationError err)
    Nothing -> do
      -- Validation succeeded; now we update the indexes and the managed datums.
      -- The new mcstIndex is just `ix'`; the new mcstDatums is computed by
      -- removing the datum hashes have been consumed and adding
      -- those that have been created in `tx`.
      let consumedIns = map Pl.txInRef $ Pl.getCardanoTxInputs tx ++ Pl.getCardanoTxCollateralInputs tx
      consumedDHs <- catMaybes <$> mapM (fmap Pl.txOutDatumHash . outFromOutRef lparams) consumedIns
      let consumedDHs' = M.fromList $ zip consumedDHs (repeat ())
      modify'
        ( \st ->
            st
              { mcstIndex = ix',
                mcstDatums = (mcstDatums st `M.difference` consumedDHs') `M.union` Pl.getCardanoTxData tx
              }
        )
      return $ Pl.getCardanoTxId tx

-- | Check 'utxosSuchThat' for details
utxosSuchThat' ::
  forall a m.
  (Monad m, Pl.FromData a) =>
  Pl.Address ->
  (Maybe a -> Pl.Value -> Bool) ->
  MockChainT m [(SpendableOut, Maybe a)]
utxosSuchThat' addr datumPred = do
  ix <- gets (Pl.getIndex . mcstIndex)
  let ix' = M.filter ((== addr) . Pl.txOutAddress) ix
  mapMaybe (fmap assocl . rstr) <$> mapM (\(oref, out) -> (oref,) <$> go oref out) (M.toList ix')
  where
    go :: Pl.TxOutRef -> Pl.TxOut -> MockChainT m (Maybe (Pl.ChainIndexTxOut, Maybe a))
    go oref txout = do
      -- We begin by attempting to lookup the given datum hash in our map of managed datums.
      managedDatums <- gets mcstDatums
      let !(sout, mdatum) = toChainIndexTxOut txout (Just managedDatums)
      case sout of
        Pl.PublicKeyChainIndexTxOut {Pl._ciTxOutValue} -> do
          let ma = mdatum >>= Pl.fromBuiltinData . Pl.getDatum
          if datumPred ma _ciTxOutValue
            then return $ Just (sout, ma)
            else return Nothing
        Pl.ScriptChainIndexTxOut {Pl._ciTxOutValue, Pl._ciTxOutScriptDatum} -> do
          datum <- maybe (fail $ "Unmanaged datum with hash: " ++ show (fst _ciTxOutScriptDatum) ++ " at: " ++ show oref) return mdatum
          a <-
            maybe
              (fail $ "Can't convert from builtin data at: " ++ show oref ++ "; are you sure this is the right type?")
              return
              (Pl.fromBuiltinData (Pl.getDatum datum))
          if datumPred (Just a) _ciTxOutValue
            then return $ Just (sout, Just a)
            else return Nothing

-- | Generates an unbalanced transaction from a skeleton; A
--  transaction is unbalanced whenever @inputs + mints != outputs + fees@.
--  In order to submit a transaction, it must be balanced, otherwise
--  we will see a @ValueNotPreserved@ error.
--
--  See "Cooked.Tx.Balance" for balancing capabilities or stick to
--  'generateTx', which generates /and/ balances a transaction.
generateUnbalTx :: Pl.Params -> TxSkel -> Either MockChainError Pl.UnbalancedTx
generateUnbalTx cfg (TxSkel {txConstraints}) =
  let (lkups, constrs) = toLedgerConstraint @Constraints @Void (toConstraints txConstraints)
   in first MCETxError $ Pl.mkTx cfg lkups constrs

myAdjustUnbalTx :: Pl.Params -> Pl.UnbalancedTx -> Pl.UnbalancedTx
myAdjustUnbalTx lparams utx =
  case Pl.adjustUnbalancedTx lparams utx of
    Left err -> error (show err)
    Right (_, res) -> res

-- | Check 'generateTx' for details
generateTx' :: (Monad m) => TxSkel -> MockChainT m Pl.Tx
generateTx' skel@(TxSkel _ _ constraintsSpec) = do
  modify $ updateDatumStr skel
  signers <- askSigners
  cfg <- params
  case generateUnbalTx cfg skel of
    Left err -> throwError err
    Right ubtx -> do
      let adjust = if adjustUnbalTx opts then myAdjustUnbalTx cfg else id
      let (_ :=>: outputConstraints) = toConstraints constraintsSpec
      let reorderedUbtx =
            if forceOutputOrdering opts
              then applyTxOutConstraintOrder cfg outputConstraints ubtx
              else ubtx
      -- optionally apply a transformation before balancing
      let modifiedUbtx = applyRawModOnUnbalancedTx (unsafeModTx opts) reorderedUbtx
      (_, balancedTx) <- balanceTxFrom cfg (balanceOutputPolicy opts) (not $ balance opts) (collateral opts) (NE.head signers) (adjust modifiedUbtx)
      return $
        foldl
          (flip txAddSignature)
          -- optionally apply a transformation to a balanced tx before sending it in.
          (applyRawModOnBalancedTx (unsafeModTx opts) balancedTx)
          (NE.toList signers)
  where
    opts = txOpts skel

    -- Update the map of pretty printed representations in the mock chain state
    updateDatumStr :: TxSkel -> MockChainSt -> MockChainSt
    updateDatumStr TxSkel {txConstraints} st@MockChainSt {mcstStrDatums} =
      st
        { mcstStrDatums =
            M.union mcstStrDatums . extractDatumStr . toConstraints $ txConstraints
        }

    -- Order outputs according to the order of output constraints
    applyTxOutConstraintOrder :: Pl.Params -> [OutConstraint] -> Pl.UnbalancedTx -> Pl.UnbalancedTx
    applyTxOutConstraintOrder lparams' ocs utx =
      let Right tx = Pl.unBalancedTxTx utx
          txOuts' = orderTxOutputs lparams' ocs . Pl.txOutputs $ tx
       in utx & Pl.tx . Pl.outputs .~ txOuts'

-- | Sets the 'Pl.txFee' and 'Pl.txValidRange' according to our environment. The transaction
-- fee gets set realistically, based on a fixpoint calculation taken from /plutus-apps/,
-- see https://github.com/input-output-hk/plutus-apps/blob/03ba6b7e8b9371adf352ffd53df8170633b6dffa/plutus-contract/src/Wallet/Emulator/Wallet.hs#L314
setFeeAndValidRange :: (Monad m) => BalanceOutputPolicy -> Wallet -> Pl.UnbalancedTx -> MockChainT m Pl.Tx
setFeeAndValidRange _bPol _w (Pl.UnbalancedCardanoTx _tx0 _reqSigs0 _uindex) =
  error "Impossible: we have a CardanoBuildTx"
setFeeAndValidRange bPol w (Pl.UnbalancedEmulatorTx tx0 reqSigs0 uindex) = do
  -- slot range is now already set properly in tx when generating unbalanced tx
  ps <- asks mceParams
  utxos <- pkUtxos' ps (walletPKHash w)
  let requiredSigners = S.toList reqSigs0
  case Pl.fromPlutusIndex $ Pl.UtxoIndex $ uindex <> M.fromList utxos of
    Left err -> throwError $ FailWith $ "setFeeAndValidRange: " ++ show err
    Right cUtxoIndex -> do
      -- We start with a high startingFee, but theres a chance that 'w' doesn't have enough funds
      -- so we'll see an unbalanceable error; in that case, we switch to the minimum fee and try again.
      -- That feels very much like a hack, and it is. Maybe we should witch to starting with a small
      -- fee and then increasing, but that might require more iterations until its settled.
      -- For now, let's keep it just like the folks from plutus-apps did it.
      let startingFee = Ada.lovelaceValueOf 3000000
      fee <-
        calcFee 5 startingFee requiredSigners cUtxoIndex ps tx0
          `catchError` \case
            MCEUnbalanceable BalCalcFee _ _ -> calcFee 5 (Pl.minFee tx0) requiredSigners cUtxoIndex ps tx0
            e -> throwError e
      return $ tx0 {Pl.txFee = fee}
  where
    -- Inspired by https://github.com/input-output-hk/plutus-apps/blob/03ba6b7e8b9371adf352ffd53df8170633b6dffa/plutus-contract/src/Wallet/Emulator/Wallet.hs#L314
    calcFee ::
      (Monad m) =>
      Int ->
      Pl.Value ->
      [Pl.PaymentPubKeyHash] ->
      Pl.UTxO Pl.EmulatorEra ->
      Pl.Params ->
      Pl.Tx ->
      MockChainT m Pl.Value
    calcFee n fee reqSigs cUtxoIndex lparams tx = do
      let tx1 = tx {Pl.txFee = fee}
      attemptedTx <- balanceTxFromAux lparams bPol BalCalcFee w tx1
      case Pl.estimateTransactionFee lparams cUtxoIndex reqSigs attemptedTx of
        -- necessary to capture script failure for failed cases
        Left (Left err@(Pl.Phase2, Pl.ScriptFailure _)) -> throwError $ MCEValidationError err
        Left err -> throwError $ FailWith $ "calcFee: " ++ show err
        Right newFee
          | newFee == fee -> pure newFee -- reached fixpoint
          | n == 0 -> pure (newFee PlutusTx.\/ fee) -- maximum number of iterations
          | otherwise -> calcFee (n - 1) newFee reqSigs cUtxoIndex lparams tx

balanceTxFrom ::
  (Monad m) =>
  Pl.Params ->
  BalanceOutputPolicy ->
  Bool ->
  Collateral ->
  Wallet ->
  Pl.UnbalancedTx ->
  MockChainT m ([Pl.PaymentPubKeyHash], Pl.Tx)
balanceTxFrom lparams bPol skipBalancing col w ubtx = do
  let requiredSigners = S.toList (Pl.unBalancedTxRequiredSignatories ubtx)
  colTxIns <- calcCollateral lparams w col
  tx <-
    setFeeAndValidRange bPol w $
      ubtx & Pl.tx . Pl.collateralInputs .~ colTxIns
  (requiredSigners,)
    <$> if skipBalancing
      then return tx
      else balanceTxFromAux lparams bPol BalFinalizing w tx

-- | Calculates the collateral for a transaction by:
--   - Ensures that the selected utxos contains at least (collateral_percentage / 100) * min tranasction fee
--   - Ensures that the number of selected utxos does not exceed maxCollateralInputs
calcCollateral :: (Monad m) => Pl.Params -> Wallet -> Collateral -> MockChainT m [Pl.TxInput]
calcCollateral lparams w col = do
  orefs <- case col of
    -- We're given a specific utxo to use as collateral
    CollateralUtxos r -> return r
    -- We must pick them; we'll first select
    CollateralAuto -> do
      souts <- map fst <$> pkUtxosSuchThat @Void (walletPKHash w) (noDatum .&& valueSat hasOnlyAda)
      -- To simplify things we are considering a min transaction fee of 2 Ada
      let minFeeValue = 2000000
          mCollateralPercentage = C.protocolParamCollateralPercent $ Pl.pProtocolParams lparams
          collateralValue = maybe minFeeValue ((computeCollateralValue minFeeValue) . fromIntegral) mCollateralPercentage
          filtered_souts = utxosWithCollateralValue souts collateralValue
      when (null filtered_souts) $
        throwError MCENoSuitableCollateral
      return $ map fst filtered_souts
  return $ map (`Pl.TxInput` Pl.TxConsumePublicKeyAddress) orefs
  where
    utxosWithCollateralValue :: [SpendableOut] -> Integer -> [SpendableOut]
    utxosWithCollateralValue utxos collateralValue =
      -- sorting list in descending order w.r.t. ada value
      let sorted_list = L.sortBy (\(_, txout1) (_, txout2) -> compare (adaVal (Pl._ciTxOutValue txout2)) (adaVal (Pl._ciTxOutValue txout1))) utxos
          acc_l = L.scanl1 (+) $ L.map (\(_, t) -> adaVal (Pl._ciTxOutValue t)) sorted_list
       in case L.findIndex (\i -> i >= collateralValue) acc_l of
            Just idx ->
              --- check if number of utxos required does not exceed maxCollateralInputs
              let maxInputs = maybe (idx + 1) fromIntegral (C.protocolParamMaxCollateralInputs $ Pl.pProtocolParams lparams)
               in if idx + 1 <= maxInputs
                    then L.take (idx + 1) sorted_list
                    else []
            Nothing -> []

    computeCollateralValue :: Integer -> Integer -> Integer
    computeCollateralValue minFeeValue collateralPercentage =
      let r_collateral = (R.unsafeRatio collateralPercentage 100) Pl.* (R.fromInteger minFeeValue)
          i_round = R.truncate r_collateral
       in if R.fromInteger i_round < r_collateral
            then i_round + 1
            else i_round

balanceTxFromAux :: (Monad m) => Pl.Params -> BalanceOutputPolicy -> BalanceStage -> Wallet -> Pl.Tx -> MockChainT m Pl.Tx
balanceTxFromAux lparams utxoPolicy stage w tx = do
  bres <- calcBalanceTx lparams w tx
  case applyBalanceTx lparams utxoPolicy w bres tx of
    Just tx' -> return tx'
    Nothing -> throwError $ MCEUnbalanceable stage tx bres

data BalanceTxRes = BalanceTxRes
  { newInputs :: [Pl.TxOutRef],
    returnValue :: Pl.Value,
    remainderUtxos :: [(Pl.TxOutRef, Pl.TxOut)]
  }
  deriving (Eq, Show)

-- | Calculate the changes needed to balance a transaction with money from a given wallet.
-- Every transaction that is sent to the chain must be balanced, that is: @inputs + mint == outputs + fee@.
calcBalanceTx :: (Monad m) => Pl.Params -> Wallet -> Pl.Tx -> MockChainT m BalanceTxRes
calcBalanceTx lparams w tx = do
  -- We start by gathering all the inputs and summing it
  lhsInputs <- mapM (outFromOutRef lparams . Pl.txInputRef) (Pl.txInputs tx)
  let lhs = mappend (mconcat $ map Pl.txOutValue lhsInputs) (Pl.txMint tx)
  let rhs = mappend (mconcat $ map Pl.txOutValue $ Pl.txOutputs tx) (Pl.txFee tx)
  let wPKH = walletPKHash w
  let usedInTxIns = S.fromList $ Pl.txInputRef <$> Pl.txInputs tx
  allUtxos <- pkUtxos' lparams wPKH
  -- It is important that we only consider utxos that have not been spent in the transaction as "available"
  let availableUtxos = filter ((`S.notMember` usedInTxIns) . fst) allUtxos
  let (usedUTxOs, leftOver, excess) = balanceWithUTxOs (rhs Pl.- lhs) availableUtxos
  return $
    BalanceTxRes
      { -- Now, we will add the necessary utxos to the transaction,
        newInputs = usedUTxOs,
        -- Pay to wPKH whatever is leftOver from newTxIns and whatever was excessive to begin with
        returnValue = leftOver <> excess,
        -- We also return the remainder utxos that could still be used in case
        -- we can't 'applyBalanceTx' this 'BalanceTxRes'.
        remainderUtxos = filter ((`L.notElem` usedUTxOs) . fst) availableUtxos
      }

-- | Once we calculated what is needed to balance a transaction @tx@, we still need to
-- apply those changes to @tx@. Because of the 'min ada' constraint, this
-- might not be possible: imagine the leftover is less than the computed min ada, but
-- the transaction has no output addressed to the sending wallet. If we just
-- create a new ouput for @w@ and place the leftover there the resulting tx will fail to validate
-- with "LessThanMinAdaPerUTxO" error. Instead, we need to consume yet another UTxO belonging to @w@ to
-- then create the output with the proper leftover. If @w@ has no UTxO, then there's no
-- way to balance this transaction.
applyBalanceTx :: Pl.Params -> BalanceOutputPolicy -> Wallet -> BalanceTxRes -> Pl.Tx -> Maybe Pl.Tx
applyBalanceTx lparams utxoPolicy w (BalanceTxRes newTxIns leftover remainders) tx = do
  -- Here we'll try a few things, in order, until one of them succeeds:
  --   1. If allowed by the utxoPolicy, pick out the best possible output to adjust and adjust it as long as it remains with
  --      more than the computed min ada. No need for additional inputs. The "best possible" here means the ada-only
  --      utxo with the most ada and without any datum hash. If the policy doesn't allow modifying an
  --      existing utxo or no such utxo exists, we move on to the next option;
  --   2. if the leftover is more than the computed min ada and (1) wasn't possible, create a new output
  --      to return leftover. No need for additional inputs.
  --   3. Attempt to consume other possible utxos from 'w' in order to combine them
  --      and return the leftover.

  let adjustOutputs = case utxoPolicy of
        DontAdjustExistingOutput -> empty
        AdjustExistingOutput -> wOutsBest >>= fmap ([],) . adjustOutputValueAt (<> leftover) (Pl.txOutputs tx)

  (txInsDelta, txOuts') <- do
    let txout = mkOutWithVal leftover
    asum $
      [ adjustOutputs, -- 1.
        guard (isAtLeastMinAda txout leftover) >> return ([], Pl.txOutputs tx ++ [txout]) -- 2.
      ]
        ++ map (fmap (second (Pl.txOutputs tx ++)) . consumeRemainder) (sortByMoreAda remainders) -- 3.
  let newTxIns' = map (`Pl.TxInput` Pl.TxConsumePublicKeyAddress) (newTxIns ++ txInsDelta)
  return $
    tx
      { Pl.txInputs = Pl.txInputs tx <> newTxIns',
        Pl.txOutputs = txOuts'
      }
  where
    wPKH = walletPKHash w
    mkOutWithVal v = mkTxOut lparams (walletAddress w) v Nothing C.ReferenceScriptNone

    -- The best output to attempt and modify, if any, is the one with the most ada,
    -- which is at the head of wOutsIxSorted:
    wOutsBest = fst <$> L.uncons wOutsIxSorted

    -- The indexes of outputs belonging to w sorted by amount of ada.
    wOutsIxSorted :: [Int]
    wOutsIxSorted =
      map fst $
        sortByMoreAda $
          filter ((== Just wPKH) . onlyAdaPkTxOut . snd) $
            zip [0 ..] (Pl.txOutputs tx)

    sortByMoreAda :: [(a, Pl.TxOut)] -> [(a, Pl.TxOut)]
    sortByMoreAda = L.sortBy (flip compare `on` (adaVal . Pl.txOutValue . snd))

    isAtLeastMinAda :: Pl.TxOut -> Pl.Value -> Bool
    isAtLeastMinAda txout v =
      let val = Pl.txOutValue txout <> Ada.toValue Pl.minAdaTxOut
          withMinAda = either (\err -> error $ "isAtLeastMinAda: cannot create txOutValue" ++ show err) id (Pl.toCardanoTxOutValue val)
          txout' = txout & Pl.outValue .~ withMinAda
          minAdaTxOut' = Pl.evaluateMinLovelaceOutput lparams (Pl.fromPlutusTxOut txout')
       in Ada.fromValue v >= minAdaTxOut'

    adjustOutputValueAt :: (Pl.Value -> Pl.Value) -> [Pl.TxOut] -> Int -> Maybe [Pl.TxOut]
    adjustOutputValueAt f xs i =
      let (pref, txout : rest) = L.splitAt i xs
          !val' = f $ Pl.txOutValue txout
          cval' = either (\err -> error $ "adjustOutputValueAt: cannot create txOutValue" ++ show err) id (Pl.toCardanoTxOutValue val')
          txout' = txout & Pl.outValue .~ cval'
       in guard (isAtLeastMinAda txout val') >> return (pref ++ txout' : rest)

    -- Given a list of available utxos; attept to consume them if they would enable the returning
    -- of the leftover.
    consumeRemainder :: (Pl.TxOutRef, Pl.TxOut) -> Maybe ([Pl.TxOutRef], [Pl.TxOut])
    consumeRemainder (remRef, remOut) =
      let !v = leftover <> Pl.txOutValue remOut
       in guard (isAtLeastMinAda remOut v) >> return ([remRef], [mkOutWithVal v])

-- * Utilities

-- | returns the number of lovelace in Value
adaVal :: Pl.Value -> Integer
adaVal = Ada.getLovelace . Ada.fromValue

-- | returns public key hash when txout contains only ada tokens and that no datum hash is specified.
onlyAdaPkTxOut :: Pl.TxOut -> Maybe Pl.PubKeyHash
onlyAdaPkTxOut txout@(Pl.txOutPubKey -> Just pkh)
  | Pl.isAdaOnlyValue (Pl.txOutValue txout) = Just pkh
  | otherwise = Nothing
onlyAdaPkTxOut _ = Nothing

addressIsPK :: Pl.Address -> Maybe Pl.PubKeyHash
addressIsPK addr = case Pl.addressCredential addr of
  Pl.PubKeyCredential pkh -> Just pkh
  _ -> Nothing

rstr :: (Monad m) => (a, m b) -> m (a, b)
rstr (a, mb) = (a,) <$> mb

assocl :: (a, (b, c)) -> ((a, b), c)
assocl (a, (b, c)) = ((a, b), c)
