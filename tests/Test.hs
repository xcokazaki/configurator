{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}

module Main where

import Prelude hiding (lookup)

import           Control.Concurrent
import           Control.Exception
import           Control.Monad
import           Data.Configurator
import           Data.Configurator.Types
import           Data.Functor
import           Data.Maybe
import           Data.Text (Text)
import qualified Data.ByteString.Lazy.Char8 as L
import           System.Directory
import           System.IO
import           Test.HUnit

main :: IO ()
main = runTestTT tests >> return ()

tests :: Test
tests = TestList [
    "load" ~: loadTest,
    "reload" ~: reloadTest
    ]

withLoad :: [Worth FilePath] -> (Config -> IO ()) -> IO ()
withLoad files t = do
    mb <- try $ load files
    case mb of
        Left (err :: SomeException) -> assertFailure (show err)
        Right cfg -> t cfg

withReload :: [Worth FilePath] -> ([Maybe FilePath] -> Config -> IO ()) -> IO ()
withReload files t = do
    tmp   <- getTemporaryDirectory
    temps <- forM files $ \f -> do
        exists <- doesFileExist (worth f)
        if exists
            then do
                (p,h) <- openBinaryTempFile tmp "test.cfg"
                L.hPut h =<< L.readFile (worth f)
                hClose h
                return (p <$ f, Just p)
            else do
                return (f, Nothing)
    flip finally (mapM_ removeFile (catMaybes (map snd temps))) $ do
        mb <- try $ autoReload autoConfig (map fst temps)
        case mb of
            Left (err :: SomeException) -> assertFailure (show err)
            Right (cfg, tid) -> t (map snd temps) cfg >> killThread tid

takeMVarTimeout :: Int -> MVar a -> IO (Maybe a)
takeMVarTimeout millis v = do
    w <- newEmptyMVar
    tid <- forkIO $ do
        putMVar w . Just =<< takeMVar v
    forkIO $ do
        threadDelay (millis * 1000)
        killThread tid
        tryPutMVar w Nothing
        return ()
    takeMVar w

loadTest :: Assertion
loadTest = withLoad [Required "resources/pathological.cfg"] $ \cfg -> do
    aa  <- lookup cfg "aa"
    assertEqual "int property" aa $ (Just 1 :: Maybe Int)

    ab  <- lookup cfg "ab"
    assertEqual "string property" ab (Just "foo" :: Maybe Text)

    acx <- lookup cfg "ac.x"
    assertEqual "nested int" acx (Just 1 :: Maybe Int)

    acy <- lookup cfg "ac.y"
    assertEqual "nested bool" acy (Just True :: Maybe Bool)

    ad <- lookup cfg "ad"
    assertEqual "simple bool" ad (Just False :: Maybe Bool)

    ae <- lookup cfg "ae"
    assertEqual "simple int 2" ae (Just 1 :: Maybe Int)

    af <- lookup cfg "af"
    assertEqual "list property" af (Just (2,3) :: Maybe (Int,Int))

    deep <- lookup cfg "ag.q-e.i_u9.a"
    assertEqual "deep bool" deep (Just False :: Maybe Bool)

reloadTest :: Assertion
reloadTest = withReload [Required "resources/pathological.cfg"] $ \[Just f] cfg -> do
    aa <- lookup cfg "aa"
    assertEqual "simple property 1" aa $ Just (1 :: Int)

    dongly <- newEmptyMVar
    wongly <- newEmptyMVar
    subscribe cfg "dongly" $ \ _ _ -> putMVar dongly ()
    subscribe cfg "wongly" $ \ _ _ -> putMVar wongly ()
    L.appendFile f "\ndongly = 1"
    r1 <- takeMVarTimeout 2000 dongly
    assertEqual "notify happened" r1 (Just ())
    r2 <- takeMVarTimeout 2000 wongly
    assertEqual "notify not happened" r2 Nothing

