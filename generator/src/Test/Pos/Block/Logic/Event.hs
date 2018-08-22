{-# LANGUAGE TypeFamilies #-}

module Test.Pos.Block.Logic.Event
       (
       -- * Running events and scenarios
         runBlockEvent
       , runBlockScenario
       , BlockScenarioResult(..)
       , lastSlot

       -- * Exceptions
       , SnapshotMissingEx(..)
       , DbNotEquivalentToSnapshot(..)
       ) where

import           Universum

import           Control.Exception.Safe (fromException)
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified GHC.Exts as IL

import           Pos.Chain.Block (Block, Blund, HeaderHash)
import           Pos.Chain.Txp (TxpConfiguration)
import           Pos.Core.Chrono (NE, NewestFirst, OldestFirst)
import           Pos.Core.Configuration (HasConfiguration)
import           Pos.Core.Exception (CardanoFatalError (..))
import           Pos.Core.NetworkMagic (RequiresNetworkMagic, makeNetworkMagic)
import           Pos.Core.Slotting (EpochOrSlot (..), SlotId, getEpochOrSlot)
import           Pos.DB.Block (BlockLrcMode, getVerifyBlocksContext',
                     rollbackBlocks, verifyAndApplyBlocks)
import           Pos.DB.Pure (DBPureDiff, MonadPureDB, dbPureDiff, dbPureDump,
                     dbPureReset)
import           Pos.DB.Txp (MonadTxpLocal)
import           Pos.Generator.BlockEvent (BlockApplyResult (..), BlockEvent,
                     BlockEvent' (..), BlockRollbackFailure (..),
                     BlockRollbackResult (..), BlockScenario,
                     BlockScenario' (..), SnapshotId, SnapshotOperation (..),
                     beaInput, beaOutValid, berInput, berOutValid)
import           Pos.Util.Util (eitherToThrow, lensOf)

import           Test.Pos.Block.Logic.Mode (BlockTestContext,
                     PureDBSnapshotsVar (..))
import           Test.Pos.Block.Logic.Util (satisfySlotCheck)
import           Test.Pos.Core.Dummy (dummyNetworkMagic)
import           Test.Pos.Crypto.Dummy (dummyProtocolMagic)

data SnapshotMissingEx = SnapshotMissingEx SnapshotId
    deriving (Show)

instance Exception SnapshotMissingEx

data DbNotEquivalentToSnapshot = DbNotEquivalentToSnapshot SnapshotId DBPureDiff
    deriving (Show)

instance Exception DbNotEquivalentToSnapshot

newtype IsExpected = IsExpected Bool

data BlockEventResult
    = BlockEventSuccess IsExpected
    | BlockEventFailure IsExpected SomeException
    | BlockEventDbChanged DbNotEquivalentToSnapshot

lastSlot :: [Block] -> Maybe SlotId
lastSlot bs =
    case mapMaybe (either (const Nothing) Just . unEpochOrSlot . getEpochOrSlot) bs of
        [] -> Nothing
        ss -> Just $ maximum ss

verifyAndApplyBlocks' ::
       ( HasConfiguration
       , BlockLrcMode BlockTestContext m
       , MonadTxpLocal m
       )
    => RequiresNetworkMagic
    -> TxpConfiguration
    -> OldestFirst NE Blund
    -> m ()
verifyAndApplyBlocks' rnm txpConfig blunds = do
    let -- We cannot simply take `getCurrentSlot` since blocks are generated in
        --`MonadBlockGen` which locally changes its current slot.  We just take
        -- the last slot of all generated blocks.
        curSlot :: Maybe SlotId
        curSlot = lastSlot (map fst . IL.toList $ blunds)
    ctx <- getVerifyBlocksContext' curSlot

    let nm = makeNetworkMagic rnm dummyProtocolMagic
    satisfySlotCheck blocks $ do
        _ :: (HeaderHash, NewestFirst [] Blund) <- eitherToThrow =<<
            verifyAndApplyBlocks dummyProtocolMagic nm txpConfig ctx True blocks
        return ()
  where
    blocks = fst <$> blunds

-- | Execute a single block event.
runBlockEvent ::
       ( BlockLrcMode BlockTestContext m
       , MonadTxpLocal m
       )
    => RequiresNetworkMagic
    -> TxpConfiguration
    -> BlockEvent
    -> m BlockEventResult

runBlockEvent rnm txpConfig (BlkEvApply ev) =
    (onSuccess <$ verifyAndApplyBlocks' rnm txpConfig (ev ^. beaInput))
        `catch` (return . onFailure)
  where
    onSuccess = case ev ^. beaOutValid of
        BlockApplySuccess -> BlockEventSuccess (IsExpected True)
        BlockApplyFailure -> BlockEventSuccess (IsExpected False)
    onFailure (e :: SomeException) = case ev ^. beaOutValid of
        BlockApplySuccess -> BlockEventFailure (IsExpected False) e
        BlockApplyFailure -> BlockEventFailure (IsExpected True) e

runBlockEvent _ _ (BlkEvRollback ev) = do
    (onSuccess <$ rollbackBlocks dummyProtocolMagic dummyNetworkMagic (ev ^. berInput))
       `catch` (return . onFailure)
  where
    onSuccess = case ev ^. berOutValid of
        BlockRollbackSuccess   -> BlockEventSuccess (IsExpected True)
        BlockRollbackFailure _ -> BlockEventSuccess (IsExpected False)
    onFailure (e :: SomeException) = case ev ^. berOutValid of
        BlockRollbackSuccess -> BlockEventFailure (IsExpected False) e
        BlockRollbackFailure brf ->
            let
                isExpected = case brf of
                    BlkRbSecurityLimitExceeded
                        | Just cfe <- fromException e
                        , CardanoFatalError msg <- cfe
                        , "security risk" `T.isInfixOf` msg ->
                          True
                        | otherwise ->
                          False
            in
                BlockEventFailure (IsExpected isExpected) e

runBlockEvent _ _ (BlkEvSnap ev) =
    (onSuccess <$ runSnapshotOperation ev)
        `catch` (return . onFailure)
  where
    onSuccess = BlockEventSuccess (IsExpected True)
    onFailure = BlockEventDbChanged


-- | Execute a snapshot operation.
runSnapshotOperation ::
       MonadPureDB BlockTestContext m
    => SnapshotOperation
    -> m ()
runSnapshotOperation snapOp = do
    PureDBSnapshotsVar snapsRef <- view (lensOf @PureDBSnapshotsVar)
    case snapOp of
        SnapshotSave snapId -> do
            currentDbState <- dbPureDump
            modifyIORef snapsRef $ Map.insert snapId currentDbState
        SnapshotLoad snapId -> do
            snap <- getSnap snapsRef snapId
            dbPureReset snap
        SnapshotEq snapId -> do
            currentDbState <- dbPureDump
            snap <- getSnap snapsRef snapId
            whenJust (dbPureDiff snap currentDbState) $ \dbDiff ->
                throwM $ DbNotEquivalentToSnapshot snapId dbDiff
  where
    getSnap snapsRef snapId = do
        mSnap <- Map.lookup snapId <$> readIORef snapsRef
        maybe (throwM $ SnapshotMissingEx snapId) return mSnap

data BlockScenarioResult
    = BlockScenarioFinishedOk
    | BlockScenarioUnexpectedSuccess
    | BlockScenarioUnexpectedFailure SomeException
    | BlockScenarioDbChanged DbNotEquivalentToSnapshot

-- | Execute a block scenario: a sequence of block events that either ends with
-- an expected failure or with a rollback to the initial state.
runBlockScenario ::
       ( MonadPureDB ctx m
       , ctx ~ BlockTestContext
       , BlockLrcMode BlockTestContext m
       , MonadTxpLocal m
       )
    => RequiresNetworkMagic
    -> TxpConfiguration
    -> BlockScenario
    -> m BlockScenarioResult
runBlockScenario _ _ (BlockScenario []) =
    return BlockScenarioFinishedOk
runBlockScenario rnm txpConfig (BlockScenario (ev:evs)) = do
    runBlockEvent rnm txpConfig ev >>= \case
        BlockEventSuccess (IsExpected isExp) ->
            if isExp
                then runBlockScenario rnm txpConfig (BlockScenario evs)
                else return BlockScenarioUnexpectedSuccess
        BlockEventFailure (IsExpected isExp) e ->
            return $ if isExp
                then BlockScenarioFinishedOk
                else BlockScenarioUnexpectedFailure e
        BlockEventDbChanged d ->
            return $ BlockScenarioDbChanged d
