-- | MCCtl backend; this is the part that actually talks to the Minecraft
--   server.
module MCCtl.Backend (
    State, start, stop, backlog, command
  ) where
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.Time.Clock
import Data.Int
import System.IO
import System.Process
import System.FilePath
import System.Directory
import System.Exit
import Control.Applicative
import Control.Monad
import Control.Concurrent
import MCCtl.Config
import MCCtl.Paths

-- | State for a single instance.
data State = State {
    -- | Minecraft server Java process handle; used to wait for server
    --   shutdown.
    stProcHdl   :: !ProcessHandle,

    -- | Server process' stdin handle. Used to send commands to the server.
    stInHdl     :: !Handle,

    -- | Server process' stdout handle. Used to extract result messages after
    --   sending a command.
    stOutHdl    :: !(MVar Handle),

    -- | Per instance and global config for instance.
    stConfig    :: !Config,

    -- | Full when the instance is done and has exited cleanly.
    stDoneLock  :: !(MVar ()),

    -- | When was the instance last (re)started?
    stStartTime :: !UTCTime
  }

-- | Start a new server process, complete with log eater and all.
start :: MVar (M.Map String State) -> Config -> IO State
start insts cfg = do
    putStrLn $ "Starting instance '" ++ name ++ "'..."
    st <- spawnServerProc cfg
    logeater <- forkIO $ discardLogLines st
    void . forkIO $ monitorServerProc st logeater
    return st
  where
    name = instanceName cfg
    monitorServerProc st logeater = do
      ec <- waitForProcess $ stProcHdl st
      killThread logeater
      case ec of
        ExitSuccess -> do
          putStrLn $ "Instance '" ++ name ++ "' exited cleanly"
          putMVar (stDoneLock st) ()
        ExitFailure _ -> do
          modifyMVar_ insts $ pure . M.delete name
          t <- getCurrentTime
          case restartOnFailure $ instanceConfig cfg of
            Restart cooldown
              | diffUTCTime t (stStartTime st) > cooldown -> do
                putStrLn $ "Instance '" ++ name ++
                           "' crashed unexpectedly; restarting!"
                modifyMVar_ insts $ \m -> do
                  newst <- start insts cfg
                  return $ M.insert name newst m
              | otherwise -> do
                putStrLn $ "Instance '" ++ name ++ "' crashed " ++
                           "unexpectedly, but is crashing too fast to be " ++
                           "restarted!"
            DontRestart -> do
                putStrLn $ "Instance '" ++ name ++ "' crashed " ++
                           "unexpectedly, but is not configured to restart!"

-- | Send a stop message to the server, then wait for it to exit.
stop :: State -> IO ()
stop st = do
  putStrLn $ "Stopping instance '" ++ (instanceName $ stConfig st)
  hPutStrLn (stInHdl st) "stop"
  hFlush $ stInHdl st
  takeMVar $ stDoneLock st

-- | Perform a command, wait for 100ms, then examine the log for a result.
command :: String -> State -> IO [BS.ByteString]
command cmd st = do
  withMVar (stOutHdl st) $ \h -> do
    discardLines h
    hPutStrLn (stInHdl st) cmd
    hFlush $ stInHdl st
    threadDelay 100000
    ls <- readLines h
    return ls

-- | Get the n latest entries in the log file.
backlog :: Int32 -> State -> IO String
backlog n st = do
    readProcess "/usr/bin/tail" ["-n", show n, logfile] ""
  where
    logfile =
      serverDirectory (instanceConfig $ stConfig st) </> "logs" </> "latest.log"

-- | Spawn a Minecraft server process.
spawnServerProc :: Config -> IO State
spawnServerProc cfg = do
    createDirectoryIfMissing True dir
    writeFile (dir </> "eula.txt") "eula=true"
    case serverProperties $ instanceConfig cfg of
      Just props -> writeFile (dir </> "server.properties") props
      _          -> return ()
    (Just i, Just o, Nothing, ph) <- createProcess cp
    State <$> pure ph
          <*> pure i
          <*> newMVar o
          <*> pure cfg
          <*> newEmptyMVar
          <*> getCurrentTime
  where
    jar = instanceJAR cfg
    dir = instanceDirectory cfg
    xms = "-Xms" ++ show (initialHeapSize $ instanceConfig cfg) ++ "M"
    xmx = "-Xmx" ++ show (maxHeapSize $ instanceConfig cfg) ++ "M"
    opts = ["-jar", jar, "nogui", xms, xmx]
    cp = CreateProcess {
        cmdspec       = RawCommand "/usr/bin/java" opts,
        cwd           = Just dir,
        env           = Nothing,
        std_in        = CreatePipe,
        std_out       = CreatePipe,
        std_err       = Inherit,
        close_fds     = False,
        create_group  = False,
        delegate_ctlc = False
      }

-- | Wait 10 seconds, then discard any lines from Minecraft's stdout.
--   Repeat indefinitely.
discardLogLines :: State -> IO ()
discardLogLines st = forever $ do
  threadDelay 10000000
  withMVar (stOutHdl st) discardLines

-- | Discard any lines currently waiting to be read from the given handle.
discardLines :: Handle -> IO ()
discardLines h = do
  rdy <- hReady h
  case rdy of
    True -> BS.hGetLine h >> discardLines h
    _    -> return ()

-- | Read any lines waiting to be read from the given handle.
readLines :: Handle -> IO [BS.ByteString]
readLines h = do
  rdy <- hReady h
  case rdy of
    True -> do
      l <- BS.hGetLine h
      ls <- readLines h
      return (l:ls)
    _    -> do
      return []