{-# LANGUAGE NumericUnderscores #-}

module Example where

import Control.Monad
import Cooked.MockChain
import Cooked.Tx.Constraints
import Data.Default (def)
import qualified Ledger as Pl
import qualified Ledger.Ada as Pl

-- * MockChain Example

-- | Start from the initial 'UtxoIndex', where each known 'wallet's have the
-- same amount of Ada, then transfers 4200 lovelace from wallet 1 to wallet 2.
-- This transfers from wallet 1 because that's the default signer of transactions
-- if nothing else is specified.
example :: Either MockChainError ((), UtxoState)
example = runMockChain $ do
  void $
    validateTxSkel $
      txSkel
        ( TxSpec
            { txSpendings = [],
              txPayments = [paysPK (walletPKHash $ wallet 2) (Pl.lovelaceValueOf 42_000_000)],
              txMinting = [],
              txTimeConstraint = Nothing,
              txSignatories = [walletPKHash (wallet 1)],
              txConstraintsMisc = []
            }
        )

alice :: Wallet
alice = wallet 1

bob :: Wallet
bob = wallet 2

alicePkh :: Pl.PubKeyHash
alicePkh = walletPKHash alice

bobPkh :: Pl.PubKeyHash
bobPkh = walletPKHash bob

ada :: Integer -> Pl.Value
ada = Pl.lovelaceValueOf . (* 1_000_000)

example2 :: Either MockChainError ((), UtxoState)
example2 = runMockChain . void $ do
  void $ validateTxConstr (txSpecPays [paysPK alicePkh (ada 42)]) `as` bob
  void $
    validateTxConstr
      ( txSpecPays
          [ paysPK bobPkh (ada 10),
            paysPK bobPkh (ada 20),
            paysPK bobPkh (ada 30)
          ]
      )
      `as` alice
