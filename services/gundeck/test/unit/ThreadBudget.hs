{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module ThreadBudget where

import Imports

import Control.Concurrent.Async
import Control.Lens
import Control.Monad.Catch (MonadCatch, catch)
import Data.Metrics.Middleware (metrics)
import Data.String.Conversions (cs)
import Data.Time
import Data.TreeDiff.Class (ToExpr)
import GHC.Generics
import Gundeck.ThreadBudget
import System.Timeout (timeout)
import System.IO (hPutStrLn)
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Test.StateMachine
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

import qualified System.Logger.Class as LC
import qualified Test.StateMachine.Types as STM
import qualified Test.StateMachine.Types.Rank2 as Rank2


----------------------------------------------------------------------
-- helpers

newtype NumberOfThreads = NumberOfThreads { fromNumberOfThreads :: Int }
  deriving (Eq, Ord, Show, Generic, ToExpr)

-- | 'microseconds' determines how long one unit lasts.  there is a trade-off of fast
-- vs. robust in this whole setup.  this type is supposed to help us find a good sweet spot.
newtype MilliSeconds = MilliSeconds { fromMilliSeconds :: Int }
  deriving (Eq, Ord, Show, Generic, ToExpr)

-- toMillisecondsCeiling 0.03      == MilliSeconds 30
-- toMillisecondsCeiling 0.003     == MilliSeconds 3
-- toMillisecondsCeiling 0.0003    == MilliSeconds 1
-- toMillisecondsCeiling 0.0000003 == MilliSeconds 1
toMillisecondsCeiling :: NominalDiffTime -> MilliSeconds
toMillisecondsCeiling = MilliSeconds . ceiling . (* 1000) . toRational

milliSecondsToNominalDiffTime :: MilliSeconds -> NominalDiffTime
milliSecondsToNominalDiffTime = fromRational . (/ 1000) . toRational . fromMilliSeconds

instance Arbitrary NumberOfThreads where
  arbitrary = NumberOfThreads <$> choose (1, 30)
  shrink (NumberOfThreads n) = NumberOfThreads <$> filter (> 0) (shrink n)

instance Arbitrary MilliSeconds where
  arbitrary = MilliSeconds <$> choose (1, 30)
  shrink (MilliSeconds n) = MilliSeconds <$> filter (> 0) (shrink n)


data LogEntry = NoBudget | Debug String | Unknown String
  deriving (Eq, Show)

makePrisms ''LogEntry

type LogHistory = MVar [LogEntry]


extractLogHistory :: (HasCallStack, MonadReader LogHistory m, MonadIO m) => m [LogEntry]
extractLogHistory = do
  logHistory <- ask
  liftIO $ modifyMVar logHistory (pure . ([],))

expectLogHistory :: (HasCallStack, MonadReader LogHistory m, MonadIO m) => ([LogEntry] -> Bool) -> m ()
expectLogHistory expected = do
  logHistory <- ask
  liftIO $ do
    found <- modifyMVar logHistory (\found -> pure ([], found))
    expected (filter (isn't _Debug) found) @? ("unexpected log data: " <> show found)

enterLogHistory :: (HasCallStack, MonadReader LogHistory m, MonadIO m) => LogEntry -> m ()
enterLogHistory entry = do
  logHistory <- ask
  liftIO $ do
    modifyMVar_ logHistory (\found -> pure (entry : found))

instance LC.MonadLogger (ReaderT LogHistory IO) where
  log level msg = do
    let raw :: String = cs $ LC.render LC.renderNetstr msg
        parsed
          | level == LC.Debug                               = Debug raw
          | "runWithBudget: out of budget." `isInfixOf` raw = NoBudget
          | otherwise                                       = Unknown raw
    enterLogHistory parsed

delayms :: MilliSeconds -> (MonadCatch m, MonadIO m) => m ()
delayms = delay' . (* 1000) . fromMilliSeconds

delayndt :: NominalDiffTime -> (MonadCatch m, MonadIO m) => m ()
delayndt = delay' . round . (* 1000) . (* 1000) . toRational

delay' :: Int -> (MonadCatch m, MonadIO m) => m ()
delay' microsecs = threadDelay microsecs `catch` \AsyncCancelled -> pure ()

burstActions
  :: HasCallStack
  => ThreadBudgetState
  -> LogHistory
  -> MilliSeconds
  -> NumberOfThreads
  -> (MonadIO m) => m ()
burstActions tbs logHistory howlong (NumberOfThreads howmany)
    = liftIO $ do
        before <- runningThreads tbs

        let budgeted = runWithBudget tbs (delayms howlong)
        replicateM_ howmany . forkIO $ runReaderT budgeted logHistory

        let waitForReady = do
              threadsAfter <- runningThreads tbs
              outOfBudgetsAfter <- length . filter (isn't _Debug) <$> readMVar logHistory
              when ( -- wait for all threads that will be created.
                     threadsAfter < min (before + howmany) (threadLimit tbs) ||
                     -- wait for all out-of-budget log entries for threads we can't afford.
                     outOfBudgetsAfter /= max 0 (before + howmany - threadLimit tbs)
                   )
                waitForReady

            -- FUTUREWORK: [upstream] using error here, this triggers an "impossible."-errors
            -- in quickcheck-state-machine, and it sometimes enters an infinite loop.
            error' = hPutStrLn stderr msg >> error "died"
              where
                msg = "\n\n\n\n*************** burstActions: timeout\n\n\n\n"

        -- wait a while, but don't hang.
        timeout 1000000 waitForReady >>= maybe error' pure

-- | Start a watcher with given params and a frequency of 10 milliseconds, so we are more
-- likely to find weird race conditions.
mkWatcher :: ThreadBudgetState -> LogHistory -> IO (Async ())
mkWatcher tbs logHistory = do
  mtr <- metrics
  async $ runReaderT (watchThreadBudgetState mtr tbs 10) logHistory
    `catch` \AsyncCancelled -> pure ()


----------------------------------------------------------------------
-- TOC

tests :: TestTree
tests = testGroup "thread budgets" $
  [ testCase "unit test" testThreadBudgets
  , testProperty "qc stm (sequential)" propSequential
  ]


----------------------------------------------------------------------
-- deterministic unit test

testThreadBudgets :: Assertion
testThreadBudgets = do
  tbs <- mkThreadBudgetState 5
  logHistory :: LogHistory <- newMVar []
  watcher <- mkWatcher tbs logHistory

  flip runReaderT logHistory $ do
    burstActions tbs logHistory (MilliSeconds 1000) (NumberOfThreads 5)
    delayms (MilliSeconds 100)
    expectLogHistory null

    burstActions tbs logHistory (MilliSeconds 1000) (NumberOfThreads 3)
    delayms (MilliSeconds 100)
    expectLogHistory (== [NoBudget, NoBudget, NoBudget])

    burstActions tbs logHistory (MilliSeconds 1000) (NumberOfThreads 3)
    delayms (MilliSeconds 100)
    expectLogHistory (== [NoBudget, NoBudget, NoBudget])

    delayms (MilliSeconds 800)

    burstActions tbs logHistory (MilliSeconds 1000) (NumberOfThreads 3)
    delayms (MilliSeconds 100)
    expectLogHistory null

    burstActions tbs logHistory (MilliSeconds 1000) (NumberOfThreads 3)
    delayms (MilliSeconds 100)
    expectLogHistory (== [NoBudget])

  cancel watcher


----------------------------------------------------------------------
-- property-based state machine tests

type State = Reference (Opaque (ThreadBudgetState, Async (), LogHistory))
type ModelState = (NumberOfThreads{- limit -}, [(NumberOfThreads, UTCTime)]{- expiry -})

-- TODO: once this works: do we really need to keep the 'State' around in here even if it's
-- symbolic?  why?  (not sure this question makes sense, i'll just keep going.)
newtype Model r = Model (Maybe (State r, ModelState))
  deriving (Show, Generic)

instance ToExpr (Model Symbolic)
instance ToExpr (Model Concrete)


data Command r
  = Init NumberOfThreads
  | Run (State r) NumberOfThreads MilliSeconds
  | Wait (State r) MilliSeconds
  deriving (Show, Generic, Generic1, Rank2.Functor, Rank2.Foldable, Rank2.Traversable)

data Response r
  = InitResponse (State r)
  | RunResponse
      { rspNow               :: UTCTime
      , rspConcreteRunning   :: Int
      , rspNumNoBudgetErrors :: Int
      , rspNewlyStarted      :: (NumberOfThreads, UTCTime)
      }
  | WaitResponse
      { rspNow               :: UTCTime
      , rspConcreteRunning   :: Int
      }
  deriving (Show, Generic, Generic1, Rank2.Functor, Rank2.Foldable, Rank2.Traversable)


generator :: Model Symbolic -> Gen (Command Symbolic)
generator (Model Nothing) = Init <$> arbitrary
generator (Model (Just (st, _))) = oneof [Run st <$> arbitrary <*> arbitrary, Wait st <$> arbitrary]

shrinker :: Command Symbolic -> [Command Symbolic]
shrinker (Init _)     = []
shrinker (Run st n m) = Wait st (MilliSeconds 1) : (Run st <$> shrink n <*> shrink m)
shrinker (Wait st n)  = Wait st <$> shrink n


initModel :: Model r
initModel = Model Nothing


-- TODO: understand all calls to 'errorMargin' in the code here; this may be related to the
-- test case failures.
-- TODO: rename.  'waitForStuff'?  anyway it's not about errors.
--
-- cannot be a full millisecond, or there will be obvious failures: if a thread is running
-- only for a millisecond, it'll be gone by the time we measure
errorMargin :: NominalDiffTime
errorMargin = 100 / (1000 * 1000)  -- 100 microseconds


semantics :: Command Concrete -> IO (Response Concrete)
semantics (Init (NumberOfThreads limit))
  = do
    tbs <- mkThreadBudgetState limit
    logHistory <- newMVar []
    watcher <- mkWatcher tbs logHistory
    pure . InitResponse . reference . Opaque $ (tbs, watcher, logHistory)

semantics (Run
            (opaque -> (tbs :: ThreadBudgetState, _, logs :: LogHistory))
            howmany howlong)
  = do
    burstActions tbs logs howlong howmany
    delayndt errorMargin  -- get rid of some fuzziness before measuring
    rspConcreteRunning   <- runningThreads tbs
    rspNumNoBudgetErrors <- length . filter (isn't _Debug) <$> (extractLogHistory `runReaderT` logs)
    rspNow               <- getCurrentTime
    let rspNewlyStarted   = (howmany, milliSecondsToNominalDiffTime howlong `addUTCTime` rspNow)
    pure RunResponse{..}

semantics (Wait
            (opaque -> (tbs :: ThreadBudgetState, _, _))
            howlong)
  = do
    delayms howlong  -- let the required time pass
    delayndt errorMargin  -- get rid of some fuzziness before measuring
    rspConcreteRunning <- runningThreads tbs  -- measure
    rspNow             <- getCurrentTime  -- time of measurement
    pure WaitResponse{..}


transition :: HasCallStack => Model r -> Command r -> Response r -> Model r
transition (Model Nothing) (Init limit) (InitResponse st)
  = Model (Just (st, (limit, [])))

-- 'Run' works asynchronously: start new threads, but return without any time passing.
transition (Model (Just (st, (limit, spent)))) Run{} RunResponse{..}
  = Model (Just (st, (limit, updateModelState rspNow spent')))
  where
    spent' = removeBlockedThreads rspNumNoBudgetErrors rspNewlyStarted : spent

-- 'Wait' makes time pass, ie. reduces the run time of running threads, and removes the ones
-- that drop below 0.
transition (Model (Just (st, (limit, spent)))) Wait{} WaitResponse{..}
  = Model (Just (st, (limit, updateModelState rspNow spent)))

transition _ _ _ = error "bad transition."


removeBlockedThreads :: Int -> (NumberOfThreads, UTCTime) -> (NumberOfThreads, UTCTime)
removeBlockedThreads remove = _1 %~ \(NumberOfThreads i) -> NumberOfThreads (max 0 (i - remove))

updateModelState :: UTCTime -> [(NumberOfThreads, UTCTime)] -> [(NumberOfThreads, UTCTime)]
updateModelState now = filter filterSpent
  where
    filterSpent :: (NumberOfThreads, UTCTime) -> Bool
    filterSpent (_, timeOfDeath) = timeOfDeath > now


precondition :: Model Symbolic -> Command Symbolic -> Logic
precondition _ _ = Top

postcondition :: Model Concrete -> Command Concrete -> Response Concrete -> Logic
postcondition (Model Nothing) (Init _) _
  = Top

postcondition model cmd@Run{} resp@RunResponse{..}
  = let Model (Just model') = transition model cmd resp
    in postcondition' model' rspConcreteRunning (Just (rspNumNoBudgetErrors, rspNewlyStarted))

postcondition model cmd@Wait{} resp@WaitResponse{..}
  = let Model (Just model') = transition model cmd resp
    in postcondition' model' rspConcreteRunning Nothing

postcondition m c r = error $ "postcondition: " <> show (m, c, r)

postcondition' :: (State Concrete, ModelState) -> Int -> Maybe (Int, (NumberOfThreads, UTCTime)) -> Logic
postcondition' (state, (NumberOfThreads modellimit, spent)) rspConcreteRunning mrun = result
  where
    result :: Logic
    result = foldl' (.&&) Top (runAndWait <> runOnly)

    runAndWait :: [Logic]
    runAndWait
      = [ Annotate "wrong thread limit"    $ rspThreadLimit     .== modellimit
        , Annotate "thread limit exceeded" $ rspConcreteRunning .<= rspThreadLimit
        , Annotate "out of sync"           $ rspConcreteRunning .== rspModelRunning
        ]

    runOnly :: [Logic]
    runOnly = case mrun of
      Nothing
        -> []
      Just (rspNumNoBudgetErrors, (NumberOfThreads rspNewlyStarted, _))
        -> [ (Top .||) $  -- TODO!
             Annotate ("wrong number of over-budget calls: " <>
                       show (rspConcreteRunning, rspNewlyStarted, rspThreadLimit)) $
             max 0 rspNumNoBudgetErrors .== max 0 (rspConcreteRunning + rspNewlyStarted - rspThreadLimit)
           ]

    rspModelRunning :: Int
    rspModelRunning = sum $ (\(NumberOfThreads n, _) -> n) <$> spent

    rspThreadLimit :: Int
    rspThreadLimit = case opaque state of (tbs, _, _) -> threadLimit tbs


mock :: HasCallStack => Model Symbolic -> Command Symbolic -> GenSym (Response Symbolic)
mock (Model Nothing) (Init _)
  = InitResponse <$> genSym
mock (Model (Just (_, (NumberOfThreads limit, spent)))) (Run _ howmany howlong)
  = do
    let rspNow               = undefined  -- doesn't appear to be needed...
        rspConcreteRunning   = sum $ (\(NumberOfThreads n, _) -> n) <$> spent
        rspNumNoBudgetErrors = rspConcreteRunning + (fromNumberOfThreads howmany) - limit
        rspNewlyStarted      = (howmany, milliSecondsToNominalDiffTime howlong `addUTCTime` rspNow)
    pure RunResponse{..}
mock (Model (Just (_, (_, spent)))) (Wait _ (MilliSeconds _))
  = do
    let rspNow             = undefined  -- doesn't appear to be needed...
        rspConcreteRunning = sum $ (\(NumberOfThreads n, _) -> n) <$> spent
    pure WaitResponse{..}
mock badmodel badcmd = error $ "impossible: " <> show (badmodel, badcmd)


sm :: StateMachine Model Command IO Response
sm = StateMachine
  { STM.initModel     = initModel
  , STM.transition    = transition
  , STM.precondition  = precondition
  , STM.postcondition = postcondition
  , STM.invariant     = Nothing
  , STM.generator     = generator
  , STM.distribution  = Nothing
  , STM.shrinker      = shrinker
  , STM.semantics     = semantics
  , STM.mock          = mock
  }


-- | Remove resources created by the concrete 'STM.Commands', namely watcher and budgeted
-- async threads.
shutdown :: Model Concrete -> MonadIO m => m ()
shutdown (Model Nothing) = pure ()
shutdown (Model (Just (opaque -> (tbs, watcher, _), _))) = liftIO $ do
  cancelAllThreads tbs
  cancel watcher

-- | FUTUREWORK: in this use case of quickcheck-state-machine it may be more interesting to
-- look at fewer, but longer command sequences.
propSequential :: Property
propSequential = forAllCommands sm Nothing $ \cmds -> monadicIO $ do
  (hist, model, res) <- runCommands sm cmds
  shutdown model
  prettyCommands sm hist (checkCommandNames cmds (res === Ok))