{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Stackage.Test
    ( runTestSuites
    ) where

import qualified Control.Concurrent as C
import           Control.Exception  (Exception, SomeException, handle, throwIO, IOException, try)
import           Control.Monad      (replicateM, unless, when, forM_)
import qualified Data.Map           as Map
import qualified Data.Set           as Set
import qualified Control.Monad.Trans.Writer as W
import Distribution.Package (Dependency (Dependency))
import           Data.Version       (parseVersion, Version (Version))
import           Data.Typeable      (Typeable)
import           Stackage.Types
import           Stackage.Util
import           System.Directory   (copyFile, createDirectory,
                                     createDirectoryIfMissing, doesFileExist, findExecutable,
                                     getDirectoryContents, removeFile,
                                     renameDirectory, canonicalizePath)
import           System.Exit        (ExitCode (ExitSuccess))
import           System.FilePath    ((<.>), (</>), takeDirectory)
import           System.IO          (IOMode (WriteMode, AppendMode),
                                     withBinaryFile)
import           System.Process     (readProcess, runProcess, waitForProcess, createProcess, proc, cwd)
import           Text.ParserCombinators.ReadP (readP_to_S)
import Data.IORef (IORef, readIORef, atomicModifyIORef, newIORef)
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Distribution.PackageDescription as PD
import           Distribution.PackageDescription.Parse (ParseResult (ParseOk),
                                                        parsePackageDescription)

runTestSuites :: BuildSettings -> BuildPlan -> IO ()
runTestSuites settings' bp = do
    settings <- fixBuildSettings settings'
    let selected' = Map.filterWithKey notSkipped $ bpPackages bp
    let testdir = "runtests"
        docdir = "haddock"
    rm_r testdir
    rm_r docdir
    createDirectory testdir
    createDirectory docdir

    putStrLn "Determining package dependencies"
    selected <- mapM (addDependencies settings (Map.keysSet selected') testdir)
              $ Map.toList selected'
    putStrLn "Running test suites"

    copyBuiltInHaddocks docdir

    cabalVersion <- getCabalVersion
    haddockFilesRef <- newIORef []
    allPass <- parFoldM
        (testWorkerThreads settings)
        (runTestSuite cabalVersion settings testdir docdir bp haddockFilesRef)
        (&&)
        True
        selected
    unless allPass $ error $ "There were failures, please see the logs in " ++ testdir
  where
    notSkipped p _ = p `Set.notMember` bpSkippedTests bp

addDependencies :: BuildSettings
                -> Set PackageName -- ^ all packages to be installed
                -> FilePath -- ^ testdir
                -> (PackageName, SelectedPackageInfo)
                -> IO (PackageName, Set PackageName, SelectedPackageInfo)
addDependencies settings allPackages testdir (packageName, spi) = do
    package' <- replaceTarball (tarballDir settings) package
    deps <- handle (\e -> print (e :: IOException) >> return Set.empty)
          $ getDeps allPackages testdir packageName package package'
    return (packageName, deps, spi)
  where
    package = packageVersionString (packageName, spiVersion spi)

getDeps :: Set PackageName -- ^ all packages to be installed
        -> FilePath -> PackageName -> String -> String -> IO (Set PackageName)
getDeps allPackages testdir (PackageName name) nameVer loc = do
    (Nothing, Nothing, Nothing, ph) <- createProcess
        (proc "cabal" ["unpack", loc, "--verbose=0"]) { cwd = Just testdir }
    ec <- waitForProcess ph
    unless (ec == ExitSuccess) $ error $ "Unable to unpack: " ++ loc
    lbs <- L.readFile $ testdir </> nameVer </> name <.> "cabal"
    case parsePackageDescription $ L8.unpack lbs of
        ParseOk _ gpd -> return $ Set.intersection allPackages $ allLibraryDeps gpd
        _ -> return Set.empty

allLibraryDeps :: PD.GenericPackageDescription -> Set PackageName
allLibraryDeps =
    maybe Set.empty (W.execWriter . goTree) . PD.condLibrary
  where
    goTree tree = do
        mapM_ goDep $ PD.condTreeConstraints tree
        forM_ (PD.condTreeComponents tree) $ \(_, y, z) -> do
            goTree y
            maybe (return ()) goTree z

    goDep (Dependency pn _) = W.tell $ Set.singleton pn

getCabalVersion :: IO CabalVersion
getCabalVersion = do
    output <- readProcess "cabal" ["--numeric-version"] ""
    case filter (null . snd) $ readP_to_S parseVersion $ filter notCRLF output of
        (Version (x:y:_) _, _):_ -> return $ CabalVersion x y
        _ -> error $ "Invalid cabal version: " ++ show output
  where
    notCRLF '\n' = False
    notCRLF '\r' = False
    notCRLF _    = True

parFoldM :: Int -- ^ number of threads
         -> ((PackageName, payload) -> IO c)
         -> (a -> c -> a)
         -> a
         -> [(PackageName, Set PackageName, payload)]
         -> IO a
parFoldM threadCount0 f g a0 bs0 = do
    ma <- C.newMVar a0
    mbs <- C.newMVar bs0
    signal <- C.newEmptyMVar
    completed <- newIORef Set.empty
    tids <- replicateM threadCount0 $ C.forkIO $ worker completed ma mbs signal
    wait threadCount0 signal tids

    unrun <- C.takeMVar mbs
    when (not $ null unrun) $
        error $ "The following tests were not run: " ++ unwords
                [x | (PackageName x, _, _) <- unrun]
    C.takeMVar ma
  where
    worker completedRef ma mbs signal =
        handle
            (C.putMVar signal . Just)
            (loop >> C.putMVar signal Nothing)
      where
        loop = do
            mb <- C.modifyMVar mbs $ \bs -> do
                completed <- readIORef completedRef
                return $ case findReady completed bs of
                    -- There's a workload ready with no deps
                    Just (b, bs') -> (bs', Just b)
                    -- No workload with no deps
                    Nothing -> (bs, Nothing)
            case mb of
                Nothing -> return ()
                Just (name, _, payload) -> do
                    c <- f (name, payload)
                    C.modifyMVar_ ma $ \a -> return $! g a c
                    atomicModifyIORef completedRef $ \s -> (Set.insert name s, ())
                    loop
    wait threadCount signal tids
        | threadCount == 0 = return ()
        | otherwise = do
            me <- C.takeMVar signal
            case me of
                Nothing -> wait (threadCount - 1) signal tids
                Just e -> do
                    mapM_ C.killThread tids
                    throwIO (e :: SomeException)

-- | Find a workload whose dependencies have been met.
findReady :: Ord key
          => Set key -- ^ workloads already complete
          -> [(key, Set key, value)]
          -> Maybe ((key, Set key, value), [(key, Set key, value)])
findReady completed =
    loop id
  where
    loop _ [] = Nothing
    loop front (x@(_, deps, _):xs)
        | Set.null $ Set.difference deps completed = Just (x, front xs)
        | otherwise = loop (front . (x:)) xs

data TestException = TestException
    deriving (Show, Typeable)
instance Exception TestException

data CabalVersion = CabalVersion Int Int
    deriving (Eq, Ord, Show)

runTestSuite :: CabalVersion
             -> BuildSettings
             -> FilePath -- ^ testdir
             -> FilePath -- ^ docdir
             -> BuildPlan
             -> IORef [(String, FilePath)] -- ^ .haddock files
             -> (PackageName, SelectedPackageInfo)
             -> IO Bool
runTestSuite cabalVersion settings testdir docdir
             bp haddockFilesRef (packageName, SelectedPackageInfo {..}) = do
    -- Set up a new environment that includes the sandboxed bin folder in PATH.
    env' <- getModifiedEnv settings
    let menv = Just $ addSandbox env'
        addSandbox = (("HASKELL_PACKAGE_SANDBOX", packageDir settings):)

    let run cmd args wdir handle' = do
            ph <- runProcess cmd args (Just wdir) menv Nothing (Just handle') (Just handle')
            ec <- waitForProcess ph
            unless (ec == ExitSuccess) $ throwIO TestException

    passed <- handle (\TestException -> return False) $ do
        case cabalFileDir settings of
            Nothing -> return ()
            Just cfd -> do
                let PackageName name = packageName
                    basename = name ++ ".cabal"
                    src = dir </> basename
                    dst = cfd </> basename
                createDirectoryIfMissing True cfd
                copyFile src dst
        getHandle WriteMode $ run "cabal" (addCabalArgs settings BSTest ["configure", "--enable-tests"]) dir

        -- Try building docs first in case tests have an expected failure.
        when (buildDocs settings) $ do
            -- https://github.com/gtk2hs/gtk2hs/issues/79
            when (packageName `Set.member` buildBeforeHaddock) $
                getHandle AppendMode $ run "cabal" ["build"] dir

            hfs <- readIORef haddockFilesRef
            let hfsOpts = flip map hfs $ \(pkgVer, hf) -> concat
                    [ "--haddock-options=--read-interface="
                    , "../"
                    , pkgVer
                    , "/,"
                    , hf
                    ]
            getHandle AppendMode $ run "cabal"
                ( "haddock"
                : "--hyperlink-source"
                : "--html"
                : "--hoogle"
                : "--html-location=../$pkg-$version/"
                : hfsOpts) dir
            let PackageName packageName' = packageName
            handle (\(_ :: IOException) -> return ()) $ renameDirectory
                (dir </> "dist" </> "doc" </> "html" </> packageName')
                (docdir </> package)

            enewPath <- try $ canonicalizePath $ docdir </> package </> packageName' <.> "haddock"
            case enewPath :: Either IOException FilePath of
                Left _ -> return () -- print e
                Right newPath -> atomicModifyIORef haddockFilesRef $ \hfs'
                    -> ((package, newPath) : hfs', ())

        when spiHasTests $ do
            getHandle AppendMode $ run "cabal" ["build"] dir
            getHandle AppendMode $ run "cabal" (concat
                [ ["test"]
                , if cabalVersion >= CabalVersion 1 20
                    then ["--show-details=streaming"] -- FIXME temporary workaround for https://github.com/haskell/cabal/issues/1810
                    else []
                ]) dir
        return True
    let expectedFailure = packageName `Set.member` bpExpectedFailures bp
    if passed
        then do
            removeFile logfile
            when expectedFailure $ putStrLn $ "   " ++ package ++ " passed, but I didn't think it would."
        else unless expectedFailure $ putStrLn $ concat
                [ "Test suite failed: "
                , package
                , "("
                , unMaintainer spiMaintainer
                , githubMentions spiGithubUser
                , ")"
                ]
    rm_r dir
    return $! passed || expectedFailure
  where
    logfile = testdir </> package <.> "log"
    dir = testdir </> package
    getHandle mode = withBinaryFile logfile mode
    package = packageVersionString (packageName, spiVersion)

    buildBeforeHaddock = Set.fromList $ map PackageName $ words =<<
        [ "gio gtk"
        ]

copyBuiltInHaddocks docdir = do
    Just ghc <- findExecutable "ghc"
    copyTree (takeDirectory ghc </> "../share/doc/ghc/html/libraries") docdir
  where
    copyTree src dest = do
        entries <- fmap (filter (\s -> s /= "." && s /= ".."))
                 $ getDirectoryContents src
        forM_ entries $ \entry -> do
            let src' = src </> entry
                dest' = dest </> entry
            isFile <- doesFileExist src'
            if isFile
                then copyFile src' dest'
                else do
                    createDirectory dest'
                    copyTree src' dest'
