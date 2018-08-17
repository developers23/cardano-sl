{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.Pos.Wallet.Web.Methods.LogicSpec
       ( spec
       ) where

import           Universum

import           Test.Hspec (Spec, describe)
import           Test.Hspec.QuickCheck (prop)

import           Pos.Chain.Txp (RequiresNetworkMagic (..))
import           Pos.Launcher (HasConfigurations)
import           Pos.Wallet.Web.Methods.Logic (getAccounts, getWallets)

import           Test.Pos.Configuration (withDefConfigurations)
import           Test.Pos.Util.QuickCheck.Property (stopProperty)
import           Test.Pos.Wallet.Web.Mode (WalletProperty)

-- TODO remove HasCompileInfo when MonadWalletWebMode will be splitted.
spec :: Spec
spec = do
    runWithNetworkMagic NMMustBeJust
    runWithNetworkMagic NMMustBeNothing

runWithNetworkMagic :: RequiresNetworkMagic -> Spec
runWithNetworkMagic requiresNetworkMagic = do
    withDefConfigurations requiresNetworkMagic $ \_ _ _ ->
        describe ("Pos.Wallet.Web.Methods (requiresNetworkMagic="
                       <> show requiresNetworkMagic <> ")") $ do
            prop emptyWalletOnStarts emptyWallet
  where
    emptyWalletOnStarts = "wallet must be empty on start"

emptyWallet :: HasConfigurations => WalletProperty ()
emptyWallet = do
    wallets <- lift getWallets
    unless (null wallets) $
        stopProperty "Wallets aren't empty"
    accounts <- lift $ getAccounts Nothing
    unless (null accounts) $
        stopProperty "Accounts aren't empty"
