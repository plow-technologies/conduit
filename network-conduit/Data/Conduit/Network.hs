{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
module Data.Conduit.Network
    ( -- * Basic utilities
      sourceSocket
    , sinkSocket
      -- * Simple TCP server/client interface.
    , Application
    , AppData
    , appSource
    , appSink
    , appSockAddr
    , appLocalAddr
      -- ** Server
    , ServerSettings
    , serverSettings
    , serverPort
    , serverHost
    , serverAfterBind
    , serverNeedLocalAddr
    , runTCPServer
    , runTCPServerWithHandle
    , ConnectionHandle (..)
      -- ** Client
    , ClientSettings
    , clientSettings
    , clientPort
    , clientHost
    , runTCPClient
      -- * Helper utilities
    , HostPreference (..)
    , bindPort
    , getSocket
    , acceptSafe
    ) where

import Prelude hiding (catch)
import Data.Conduit
import qualified Network.Socket as NS
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll, recv)
import Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Exception (throwIO, SomeException, try, finally, bracket, IOException, catch)
import Control.Monad (forever)
import Control.Monad.Trans.Control (MonadBaseControl, control)
import Control.Monad.Trans.Class (lift)
import Control.Concurrent (forkIO, threadDelay, newEmptyMVar, putMVar, takeMVar)

import Data.Conduit.Network.Internal
import Data.Conduit.Network.Utils (HostPreference)
import qualified Data.Conduit.Network.Utils as Utils

#if defined(__GLASGOW_HASKELL__) && defined(mingw32_HOST_OS)
-- Socket recv and accept calls on Windows platform cannot be interrupted when compiled with -threaded.
-- See https://ghc.haskell.org/trac/ghc/ticket/5797 for details.
-- The following enables simple workaround
#define SOCKET_ACCEPT_RECV_WORKAROUND
#endif


safeRecv :: Socket -> Int -> IO S.ByteString
#ifndef SOCKET_ACCEPT_RECV_WORKAROUND
safeRecv = recv
#else
safeRecv s buf = do
    var <- newEmptyMVar
    forkIO $ recv s buf `catch` (\(_::IOException) -> return S.empty) >>= putMVar var
    takeMVar var
#endif


-- | Stream data from the socket.
--
-- This function does /not/ automatically close the socket.
--
-- Since 0.0.0
sourceSocket :: MonadIO m => Socket -> Producer m ByteString
sourceSocket socket =
    loop
  where
    loop = do
        bs <- lift $ liftIO $ safeRecv socket 4096
        if S.null bs
            then return ()
            else yield bs >> loop

-- | Stream data to the socket.
--
-- This function does /not/ automatically close the socket.
--
-- Since 0.0.0
sinkSocket :: MonadIO m => Socket -> Consumer ByteString m ()
sinkSocket socket =
    loop
  where
    loop = await >>= maybe (return ()) (\bs -> lift (liftIO $ sendAll socket bs) >> loop)

-- | A simple TCP application.
--
-- Since 0.6.0
type Application m = AppData m -> m ()

-- | Smart constructor.
--
-- Since 0.6.0
serverSettings :: Monad m
               => Int -- ^ port to bind to
               -> HostPreference -- ^ host binding preferences
               -> ServerSettings m
serverSettings port host = ServerSettings
    { serverPort = port
    , serverHost = host
    , serverAfterBind = const $ return ()
    , serverNeedLocalAddr = False
    }


data ConnectionHandle m = ConnectionHandle { getHandle :: Socket -> NS.SockAddr -> Maybe NS.SockAddr -> m ()  }

runTCPServerWithHandle :: (MonadIO m, MonadBaseControl IO m) => ServerSettings m -> ConnectionHandle m -> m ()
runTCPServerWithHandle (ServerSettings port host afterBind needLocalAddr) handle = control $ \run -> bracket
    (liftIO $ bindPort port host)
    (liftIO . NS.sClose)
    (\socket -> run $ do
        afterBind socket
        forever $ serve socket)
  where
    serve lsocket = do
        (socket, addr) <- liftIO $ acceptSafe lsocket
        mlocal <- if needLocalAddr
                    then fmap Just $ liftIO (NS.getSocketName socket)
                    else return Nothing
        let
            handler = getHandle handle
            app' run = run (handler socket addr mlocal) >> return ()
            appClose run = app' run `finally` NS.sClose socket
        control $ \run -> forkIO (appClose run) >> run (return ())



-- | Run an @Application@ with the given settings. This function will create a
-- new listening socket, accept connections on it, and spawn a new thread for
-- each connection.
--
-- Since 0.6.0
runTCPServer :: (MonadIO m, MonadBaseControl IO m) => ServerSettings m -> Application m -> m ()
runTCPServer settings app = runTCPServerWithHandle settings (ConnectionHandle app')
  where app' socket addr mlocal = 
          let ad = AppData
                { appSource = sourceSocket socket
                , appSink = sinkSocket socket
                , appSockAddr = addr
                , appLocalAddr = mlocal
                }
          in
            app ad

-- | Smart constructor.
--
-- Since 0.6.0
clientSettings :: Monad m
               => Int -- ^ port to connect to
               -> ByteString -- ^ host to connect to
               -> ClientSettings m
clientSettings port host = ClientSettings
    { clientPort = port
    , clientHost = host
    }

-- | Run an @Application@ by connecting to the specified server.
--
-- Since 0.6.0
runTCPClient :: (MonadIO m, MonadBaseControl IO m) => ClientSettings m -> (AppData m -> m a) -> m a
runTCPClient (ClientSettings port host) app = control $ \run -> bracket
    (getSocket host port)
    (NS.sClose . fst)
    (\(s, address) -> run $ app AppData
        { appSource = sourceSocket s
        , appSink = sinkSocket s
        , appSockAddr = address
        , appLocalAddr = Nothing
        })

-- | Attempt to connect to the given host/port.
--
-- Since 0.6.0
getSocket :: ByteString -> Int -> IO (NS.Socket, NS.SockAddr)
getSocket host' port' = do
    (sock, addr) <- Utils.getSocket (S8.unpack host') port' NS.Stream
    ee <- try' $ NS.connect sock (NS.addrAddress addr)
    case ee of
        Left e -> NS.sClose sock >> throwIO e
        Right () -> return (sock, NS.addrAddress addr)
  where
    try' :: IO a -> IO (Either SomeException a)
    try' = try

-- | Attempt to bind a listening @Socket@ on the given host/port. If no host is
-- given, will use the first address available.
-- 'maxListenQueue' is topically 128 which is too short for
-- high performance servers. So, we specify 'max 2048 maxListenQueue' to
-- the listen queue.
--
-- Since 0.3.0
bindPort :: Int -> HostPreference -> IO Socket
bindPort p s = do
    sock <- Utils.bindPort p s NS.Stream
    NS.listen sock (max 2048 NS.maxListenQueue)
    return sock

-- | Try to accept a connection, recovering automatically from exceptions.
--
-- As reported by Kazu against Warp, "resource exhausted (Too many open files)"
-- may be thrown by accept(). This function will catch that exception, wait a
-- second, and then try again.
--
-- Since 0.6.0
acceptSafe :: Socket -> IO (Socket, NS.SockAddr)
acceptSafe socket =
#ifndef SOCKET_ACCEPT_RECV_WORKAROUND
    loop
#else
    do var <- newEmptyMVar
       forkIO $ loop >>= putMVar var
       takeMVar var
#endif
  where
    loop =
        NS.accept socket `catch` \(_ :: IOException) -> do
            threadDelay 1000000
            loop
