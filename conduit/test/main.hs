{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck.Monadic (assert, monadicIO, run)

import Control.Exception (IOException)
import qualified Data.Conduit as C
import qualified Data.Conduit.Lift as C
import qualified Data.Conduit.Util as C
import qualified Data.Conduit.Internal as CI
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Lazy as CLazy
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.Text as CT
import Data.Conduit (runResourceT)
import Data.Maybe   (fromMaybe,catMaybes,fromJust)
import qualified Data.List as DL
import Control.Monad.ST (runST)
import Data.Monoid
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.IORef as I
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Lazy.Char8 ()
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Control.Monad.Trans.Resource (runExceptionT, runExceptionT_, allocate, resourceForkIO)
import Control.Concurrent (threadDelay, killThread)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer (execWriter, tell, runWriterT)
import Control.Monad.Trans.State (evalStateT, get, put, modify)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Applicative (pure, (<$>), (<*>))
import Data.Functor.Identity (Identity,runIdentity)
import Control.Monad (forever, void)
import Data.Void (Void)
import qualified Control.Concurrent.MVar as M
import Control.Monad.Error (catchError, throwError, Error)
import qualified Data.Map as Map
import Control.Arrow (first)
import qualified Data.Conduit.ExtraSpec as ES
import qualified Data.Conduit.Extra.ZipConduitSpec as ZipConduit

(@=?) :: (Eq a, Show a) => a -> a -> IO ()
(@=?) = flip shouldBe

-- Quickcheck property for testing equivalence of list processing
-- functions and their conduit counterparts
equivToList :: Eq b => ([a] -> [b]) -> CI.Conduit a Identity b -> [a] -> Bool
equivToList f conduit xs =
  f xs == runIdentity (CL.sourceList xs C.$$ conduit C.=$= CL.consume)


main :: IO ()
main = hspec $ do
    describe "data loss rules" $ do
        it "consumes the source to quickly" $ do
            x <- runResourceT $ CL.sourceList [1..10 :: Int] C.$$ do
                  strings <- CL.map show C.=$ CL.take 5
                  liftIO $ putStr $ unlines strings
                  CL.fold (+) 0
            40 `shouldBe` x

        it "correctly consumes a chunked resource" $ do
            x <- runResourceT $ (CL.sourceList [1..5 :: Int] `mappend` CL.sourceList [6..10]) C.$$ do
                strings <- CL.map show C.=$ CL.take 5
                liftIO $ putStr $ unlines strings
                CL.fold (+) 0
            40 `shouldBe` x

    describe "filter" $ do
        it "even" $ do
            x <- runResourceT $ CL.sourceList [1..10] C.$$ CL.filter even C.=$ CL.consume
            x `shouldBe` filter even [1..10 :: Int]

    prop "concat" $ equivToList (concat :: [[Int]]->[Int]) CL.concat

    describe "mapFoldable" $ do
        prop "list" $
            equivToList (concatMap (:[]) :: [Int]->[Int]) (CL.mapFoldable  (:[]))
        let f x = if odd x then Just x else Nothing
        prop "Maybe" $
            equivToList (catMaybes . map f :: [Int]->[Int]) (CL.mapFoldable f)

    prop "scanl" $ equivToList (tail . scanl (+) 0 :: [Int]->[Int]) (CL.scanl (\a s -> (a+s,a+s)) 0)

    -- mapFoldableM and scanlM are fully polymorphic in type of monad
    -- so it suffice to check only with Identity.
    describe "mapFoldableM" $ do
        prop "list" $
            equivToList (concatMap (:[]) :: [Int]->[Int]) (CL.mapFoldableM (return . (:[])))
        let f x = if odd x then Just x else Nothing
        prop "Maybe" $
            equivToList (catMaybes . map f :: [Int]->[Int]) (CL.mapFoldableM (return . f))

    prop "scanl" $ equivToList (tail . scanl (+) 0 :: [Int]->[Int]) (CL.scanlM (\a s -> return (a+s,a+s)) 0)

    describe "ResourceT" $ do
        it "resourceForkIO" $ do
            counter <- I.newIORef 0
            let w = allocate
                        (I.atomicModifyIORef counter $ \i ->
                            (i + 1, ()))
                        (const $ I.atomicModifyIORef counter $ \i ->
                            (i - 1, ()))
            runResourceT $ do
                _ <- w
                _ <- resourceForkIO $ return ()
                _ <- resourceForkIO $ return ()
                sequence_ $ replicate 1000 $ do
                    tid <- resourceForkIO $ return ()
                    liftIO $ killThread tid
                _ <- resourceForkIO $ return ()
                _ <- resourceForkIO $ return ()
                return ()

            -- give enough of a chance to the cleanup code to finish
            threadDelay 1000
            res <- I.readIORef counter
            res `shouldBe` (0 :: Int)

    describe "sum" $ do
        it "works for 1..10" $ do
            x <- runResourceT $ CL.sourceList [1..10] C.$$ CL.fold (+) (0 :: Int)
            x `shouldBe` sum [1..10]
        prop "is idempotent" $ \list ->
            (runST $ CL.sourceList list C.$$ CL.fold (+) (0 :: Int))
            == sum list

    describe "foldMap" $ do
        it "sums 1..10" $ do
            Sum x <- CL.sourceList [1..(10 :: Int)] C.$$ CL.foldMap Sum
            x `shouldBe` sum [1..10]

        it "preserves order" $ do
            x <- CL.sourceList [[4],[2],[3],[1]] C.$$ CL.foldMap (++[(9 :: Int)])
            x `shouldBe` [4,9,2,9,3,9,1,9]

    describe "foldMapM" $ do
        it "sums 1..10" $ do
            Sum x <- CL.sourceList [1..(10 :: Int)] C.$$ CL.foldMapM (return . Sum)
            x `shouldBe` sum [1..10]

        it "preserves order" $ do
            x <- CL.sourceList [[4],[2],[3],[1]] C.$$ CL.foldMapM (return . (++[(9 :: Int)]))
            x `shouldBe` [4,9,2,9,3,9,1,9]

    describe "unfold" $ do
        it "works" $ do
            let f 0 = Nothing
                f i = Just (show i, i - 1)
                seed = 10 :: Int
            x <- CL.unfold f seed C.$$ CL.consume
            let y = DL.unfoldr f seed
            x `shouldBe` y

    describe "Monoid instance for Source" $ do
        it "mappend" $ do
            x <- runResourceT $ (CL.sourceList [1..5 :: Int] `mappend` CL.sourceList [6..10]) C.$$ CL.fold (+) 0
            x `shouldBe` sum [1..10]
        it "mconcat" $ do
            x <- runResourceT $ mconcat
                [ CL.sourceList [1..5 :: Int]
                , CL.sourceList [6..10]
                , CL.sourceList [11..20]
                ] C.$$ CL.fold (+) 0
            x `shouldBe` sum [1..20]

    describe "file access" $ do
        it "read" $ do
            bs <- S.readFile "conduit.cabal"
            bss <- runResourceT $ CB.sourceFile "conduit.cabal" C.$$ CL.consume
            bs @=? S.concat bss

        it "read range" $ do
            S.writeFile "tmp" "0123456789"
            bss <- runResourceT $ CB.sourceFileRange "tmp" (Just 2) (Just 3) C.$$ CL.consume
            S.concat bss `shouldBe` "234"

        it "write" $ do
            runResourceT $ CB.sourceFile "conduit.cabal" C.$$ CB.sinkFile "tmp"
            bs1 <- S.readFile "conduit.cabal"
            bs2 <- S.readFile "tmp"
            bs1 @=? bs2

        it "conduit" $ do
            runResourceT $ CB.sourceFile "conduit.cabal"
                C.$= CB.conduitFile "tmp"
                C.$$ CB.sinkFile "tmp2"
            bs1 <- S.readFile "conduit.cabal"
            bs2 <- S.readFile "tmp"
            bs3 <- S.readFile "tmp2"
            bs1 @=? bs2
            bs1 @=? bs3

    describe "zipping" $ do
        it "zipping two small lists" $ do
            res <- runResourceT $ C.zipSources (CL.sourceList [1..10]) (CL.sourceList [11..12]) C.$$ CL.consume
            res @=? zip [1..10 :: Int] [11..12 :: Int]

    describe "zipping sinks" $ do
        it "take all" $ do
            res <- runResourceT $ CL.sourceList [1..10] C.$$ C.zipSinks CL.consume CL.consume
            res @=? ([1..10 :: Int], [1..10 :: Int])
        it "take fewer on left" $ do
            res <- runResourceT $ CL.sourceList [1..10] C.$$ C.zipSinks (CL.take 4) CL.consume
            res @=? ([1..4 :: Int], [1..10 :: Int])
        it "take fewer on right" $ do
            res <- runResourceT $ CL.sourceList [1..10] C.$$ C.zipSinks CL.consume (CL.take 4)
            res @=? ([1..10 :: Int], [1..4 :: Int])

    describe "Monad instance for Sink" $ do
        it "binding" $ do
            x <- runResourceT $ CL.sourceList [1..10] C.$$ do
                _ <- CL.take 5
                CL.fold (+) (0 :: Int)
            x `shouldBe` sum [6..10]

    describe "Applicative instance for Sink" $ do
        it "<$> and <*>" $ do
            x <- runResourceT $ CL.sourceList [1..10] C.$$
                (+) <$> pure 5 <*> CL.fold (+) (0 :: Int)
            x `shouldBe` sum [1..10] + 5

    describe "resumable sources" $ do
        it "simple" $ do
            (x, y, z) <- runResourceT $ do
                let src1 = CL.sourceList [1..10 :: Int]
                (src2, x) <- src1 C.$$+ CL.take 5
                (src3, y) <- src2 C.$$++ CL.fold (+) 0
                z <- src3 C.$$+- CL.consume
                return (x, y, z)
            x `shouldBe` [1..5] :: IO ()
            y `shouldBe` sum [6..10]
            z `shouldBe` []

    describe "conduits" $ do
        it "map, left" $ do
            x <- runResourceT $
                CL.sourceList [1..10]
                    C.$= CL.map (* 2)
                    C.$$ CL.fold (+) 0
            x `shouldBe` 2 * sum [1..10 :: Int]

        it "map, left >+>" $ do
            x <- runResourceT $
                CI.ConduitM
                    (CI.unConduitM (CL.sourceList [1..10])
                    CI.>+> CI.injectLeftovers (CI.unConduitM $ CL.map (* 2)))
                    C.$$ CL.fold (+) 0
            x `shouldBe` 2 * sum [1..10 :: Int]

        it "map, right" $ do
            x <- runResourceT $
                CL.sourceList [1..10]
                    C.$$ CL.map (* 2)
                    C.=$ CL.fold (+) 0
            x `shouldBe` 2 * sum [1..10 :: Int]

        it "groupBy" $ do
            let input = [1::Int, 1, 2, 3, 3, 3, 4, 5, 5]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.groupBy (==)
                    C.=$ CL.consume
            x `shouldBe` DL.groupBy (==) input

        it "groupBy (nondup begin/end)" $ do
            let input = [1::Int, 2, 3, 3, 3, 4, 5]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.groupBy (==)
                    C.=$ CL.consume
            x `shouldBe` DL.groupBy (==) input

        it "mapMaybe" $ do
            let input = [Just (1::Int), Nothing, Just 2, Nothing, Just 3]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.mapMaybe ((+2) <$>)
                    C.=$ CL.consume
            x `shouldBe` [3, 4, 5]

        it "mapMaybeM" $ do
            let input = [Just (1::Int), Nothing, Just 2, Nothing, Just 3]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.mapMaybeM (return . ((+2) <$>))
                    C.=$ CL.consume
            x `shouldBe` [3, 4, 5]

        it "catMaybes" $ do
            let input = [Just (1::Int), Nothing, Just 2, Nothing, Just 3]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.catMaybes
                    C.=$ CL.consume
            x `shouldBe` [1, 2, 3]

        it "concatMap" $ do
            let input = [1, 11, 21]
            x <- runResourceT $ CL.sourceList input
                    C.$$ CL.concatMap (\i -> enumFromTo i (i + 9))
                    C.=$ CL.fold (+) (0 :: Int)
            x `shouldBe` sum [1..30]

        it "bind together" $ do
            let conduit = CL.map (+ 5) C.=$= CL.map (* 2)
            x <- runResourceT $ CL.sourceList [1..10] C.$= conduit C.$$ CL.fold (+) 0
            x `shouldBe` sum (map (* 2) $ map (+ 5) [1..10 :: Int])

#if !FAST
    describe "isolate" $ do
        it "bound to resumable source" $ do
            (x, y) <- runResourceT $ do
                let src1 = CL.sourceList [1..10 :: Int]
                (src2, x) <- src1 C.$= CL.isolate 5 C.$$+ CL.consume
                y <- src2 C.$$+- CL.consume
                return (x, y)
            x `shouldBe` [1..5]
            y `shouldBe` []

        it "bound to sink, non-resumable" $ do
            (x, y) <- runResourceT $ do
                CL.sourceList [1..10 :: Int] C.$$ do
                    x <- CL.isolate 5 C.=$ CL.consume
                    y <- CL.consume
                    return (x, y)
            x `shouldBe` [1..5]
            y `shouldBe` [6..10]

        it "bound to sink, resumable" $ do
            (x, y) <- runResourceT $ do
                let src1 = CL.sourceList [1..10 :: Int]
                (src2, x) <- src1 C.$$+ CL.isolate 5 C.=$ CL.consume
                y <- src2 C.$$+- CL.consume
                return (x, y)
            x `shouldBe` [1..5]
            y `shouldBe` [6..10]

        it "consumes all data" $ do
            x <- runResourceT $ CL.sourceList [1..10 :: Int] C.$$ do
                CL.isolate 5 C.=$ CL.sinkNull
                CL.consume
            x `shouldBe` [6..10]

    describe "lazy" $ do
        it' "works inside a ResourceT" $ runResourceT $ do
            counter <- liftIO $ I.newIORef 0
            let incr i = do
                    istate <- liftIO $ I.newIORef $ Just (i :: Int)
                    let loop = do
                            res <- liftIO $ I.atomicModifyIORef istate ((,) Nothing)
                            case res of
                                Nothing -> return ()
                                Just x -> do
                                    count <- liftIO $ I.atomicModifyIORef counter
                                        (\j -> (j + 1, j + 1))
                                    liftIO $ count `shouldBe` i
                                    C.yield x
                                    loop
                    loop
            nums <- CLazy.lazyConsume $ mconcat $ map incr [1..10]
            liftIO $ nums `shouldBe` [1..10]

        it' "returns nothing outside ResourceT" $ do
            bss <- runResourceT $ CLazy.lazyConsume $ CB.sourceFile "test/main.hs"
            bss `shouldBe` []

        it' "works with pure sources" $ do
            nums <- CLazy.lazyConsume $ forever $ C.yield 1
            take 100 nums `shouldBe` replicate 100 (1 :: Int)

    describe "sequence" $ do
        it "simple sink" $ do
            let sumSink = do
                    ma <- CL.head
                    case ma of
                        Nothing -> return 0
                        Just a  -> (+a) . fromMaybe 0 <$> CL.head

            res <- runResourceT $ CL.sourceList [1..11 :: Int]
                             C.$= CL.sequence sumSink
                             C.$$ CL.consume
            res `shouldBe` [3, 7, 11, 15, 19, 11]

        it "sink with unpull behaviour" $ do
            let sumSink = do
                    ma <- CL.head
                    case ma of
                        Nothing -> return 0
                        Just a  -> (+a) . fromMaybe 0 <$> CL.peek

            res <- runResourceT $ CL.sourceList [1..11 :: Int]
                             C.$= CL.sequence sumSink
                             C.$$ CL.consume
            res `shouldBe` [3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 11]

#endif

    describe "peek" $ do
        it "works" $ do
            (a, b) <- runResourceT $ CL.sourceList [1..10 :: Int] C.$$ do
                a <- CL.peek
                b <- CL.consume
                return (a, b)
            (a, b) `shouldBe` (Just 1, [1..10])

    describe "text" $ do
        let go enc tenc tdec cenc = describe enc $ do
                prop "single chunk" $ \chars -> runST $ runExceptionT_ $ do
                    let tl = TL.pack chars
                        lbs = tenc tl
                        src = CL.sourceList $ L.toChunks lbs
                    ts <- src C.$= CT.decode cenc C.$$ CL.consume
                    return $ TL.fromChunks ts == tl
                prop "many chunks" $ \chars -> runIdentity $ runExceptionT_ $ do
                    let tl = TL.pack chars
                        lbs = tenc tl
                        src = mconcat $ map (CL.sourceList . return . S.singleton) $ L.unpack lbs

                    ts <- src C.$= CT.decode cenc C.$$ CL.consume
                    return $ TL.fromChunks ts == tl

                -- Check whether raw bytes are decoded correctly, in
                -- particular that Text decoding produces an error if
                -- and only if Conduit does.
                prop "raw bytes" $ \bytes ->
                    let lbs = L.pack bytes
                        src = CL.sourceList $ L.toChunks lbs
                        etl = C.runException $ src C.$= CT.decode cenc C.$$ CL.consume
                        tl' = tdec lbs
                    in  case etl of
                          (Left _) -> (return $! TL.toStrict tl') `shouldThrow` anyException
                          (Right tl) -> TL.fromChunks tl `shouldBe` tl'
                prop "encoding" $ \chars -> runIdentity $ runExceptionT_ $ do
                    let tss = map T.pack chars
                        lbs = tenc $ TL.fromChunks tss
                        src = mconcat $ map (CL.sourceList . return) tss
                    bss <- src C.$= CT.encode cenc C.$$ CL.consume
                    return $ L.fromChunks bss == lbs
                prop "valid then invalid" $ \x y chars -> runIdentity $ runExceptionT_ $ do
                    let tss = map T.pack ([x, y]:chars)
                        ts = T.concat tss
                        lbs = tenc (TL.fromChunks tss) `L.append` "\0\0\0\0\0\0\0"
                        src = mapM_ C.yield $ L.toChunks lbs
                    Just x' <- src C.$$ CT.decode cenc C.=$ C.await
                    return $ x' `T.isPrefixOf` ts
        go "utf8" TLE.encodeUtf8 TLE.decodeUtf8 CT.utf8
        go "utf16_le" TLE.encodeUtf16LE TLE.decodeUtf16LE CT.utf16_le
        go "utf16_be" TLE.encodeUtf16BE TLE.decodeUtf16BE CT.utf16_be
        go "utf32_le" TLE.encodeUtf32LE TLE.decodeUtf32LE CT.utf32_le
        go "utf32_be" TLE.encodeUtf32BE TLE.decodeUtf32BE CT.utf32_be
        it "mixed utf16 and utf8" $ do
            let bs = "8\NUL:\NULu\NUL\215\216\217\218"
                src = C.yield bs C.$= CT.decode CT.utf16_le
            text <- src C.$$ C.await
            text `shouldBe` Just "8:u"
            (src C.$$ CL.sinkNull) `shouldThrow` anyException
        it "invalid utf8" $ do
            let bs = S.pack [0..255]
                src = C.yield bs C.$= CT.decode CT.utf8
            text <- src C.$$ C.await
            text `shouldBe` Just (T.pack $ map toEnum [0..127])
            (src C.$$ CL.sinkNull) `shouldThrow` anyException
        it "catch UTF8 exceptions" $ do
            let badBS = "this is good\128\128\0that was bad"

                grabExceptions inner = C.catchC
                    (inner C.=$= CL.map Right)
                    (\e -> C.yield (Left (e :: CT.TextException)))

            res <- C.yield badBS C.$$ (,)
                <$> (grabExceptions (CT.decode CT.utf8) C.=$ CL.consume)
                <*> CL.consume

            first (map (either (Left . show) Right)) res `shouldBe`
                ( [ Right "this is good"
                  , Left $ show $ CT.NewDecodeException "UTF-8" 12 "\128\128\0t"
                  ]
                , ["\128\128\0that was bad"]
                )
        it "catch UTF8 exceptions, pure" $ do
            let badBS = "this is good\128\128\0that was bad"

                grabExceptions inner = do
                    res <- C.runExceptionC $ inner C.=$= CL.map Right
                    case res of
                        Left e -> C.yield $ Left e
                        Right () -> return ()

            let res = runIdentity $ C.yield badBS C.$$ (,)
                        <$> (grabExceptions (CT.decode CT.utf8) C.=$ CL.consume)
                        <*> CL.consume

            first (map (either (Left . show) Right)) res `shouldBe`
                ( [ Right "this is good"
                  , Left $ show $ CT.NewDecodeException "UTF-8" 12 "\128\128\0t"
                  ]
                , ["\128\128\0that was bad"]
                )
        it "catch UTF8 exceptions, catchExceptionC" $ do
            let badBS = "this is good\128\128\0that was bad"

                grabExceptions inner = C.catchExceptionC
                    (inner C.=$= CL.map Right)
                    (\e -> C.yield $ Left e)

            let res = C.runException_ $ C.yield badBS C.$$ (,)
                        <$> (grabExceptions (CT.decode CT.utf8) C.=$ CL.consume)
                        <*> CL.consume

            first (map (either (Left . show) Right)) res `shouldBe`
                ( [ Right "this is good"
                  , Left $ show $ CT.NewDecodeException "UTF-8" 12 "\128\128\0t"
                  ]
                , ["\128\128\0that was bad"]
                )
        it "catch UTF8 exceptions, catchExceptionC, decodeUtf8" $ do
            let badBS = "this is good\128\128\0that was bad"

                grabExceptions inner = C.catchExceptionC
                    (inner C.=$= CL.map Right)
                    (\e -> C.yield $ Left e)

            let res = C.runException_ $ C.yield badBS C.$$ (,)
                        <$> (grabExceptions CT.decodeUtf8 C.=$ CL.consume)
                        <*> CL.consume

            first (map (either (Left . show) Right)) res `shouldBe`
                ( [ Right "this is good"
                  , Left $ show $ CT.NewDecodeException "UTF-8" 12 "\128\128\0t"
                  ]
                , ["\128\128\0that was bad"]
                )

    describe "text lines" $ do
        it "works across split lines" $
            (CL.sourceList [T.pack "abc", T.pack "d\nef"] C.$= CT.lines C.$$ CL.consume) ==
                [[T.pack "abcd", T.pack "ef"]]
        it "works with multiple lines in an item" $
            (CL.sourceList [T.pack "ab\ncd\ne"] C.$= CT.lines C.$$ CL.consume) ==
                [[T.pack "ab", T.pack "cd", T.pack "e"]]
        it "works with ending on a newline" $
            (CL.sourceList [T.pack "ab\n"] C.$= CT.lines C.$$ CL.consume) ==
                [[T.pack "ab"]]
        it "works with ending a middle item on a newline" $
            (CL.sourceList [T.pack "ab\n", T.pack "cd\ne"] C.$= CT.lines C.$$ CL.consume) ==
                [[T.pack "ab", T.pack "cd", T.pack "e"]]
        it "is not too eager" $ do
            x <- CL.sourceList ["foobarbaz", error "ignore me"] C.$$ CT.decode CT.utf8 C.=$ CL.head
            x `shouldBe` Just "foobarbaz"

    describe "text lines bounded" $ do
        it "works across split lines" $
            (CL.sourceList [T.pack "abc", T.pack "d\nef"] C.$= CT.linesBounded 80 C.$$ CL.consume) ==
                [[T.pack "abcd", T.pack "ef"]]
        it "works with multiple lines in an item" $
            (CL.sourceList [T.pack "ab\ncd\ne"] C.$= CT.linesBounded 80 C.$$ CL.consume) ==
                [[T.pack "ab", T.pack "cd", T.pack "e"]]
        it "works with ending on a newline" $
            (CL.sourceList [T.pack "ab\n"] C.$= CT.linesBounded 80 C.$$ CL.consume) ==
                [[T.pack "ab"]]
        it "works with ending a middle item on a newline" $
            (CL.sourceList [T.pack "ab\n", T.pack "cd\ne"] C.$= CT.linesBounded 80 C.$$ CL.consume) ==
                [[T.pack "ab", T.pack "cd", T.pack "e"]]
        it "is not too eager" $ do
            x <- CL.sourceList ["foobarbaz", error "ignore me"] C.$$ CT.decode CT.utf8 C.=$ CL.head
            x `shouldBe` Just "foobarbaz"
        it "throws an exception when lines are too long" $ do
            x <- C.runExceptionT $ CL.sourceList ["hello\nworld"] C.$$ CT.linesBounded 4 C.=$ CL.consume
            show x `shouldBe` show (Left $ CT.LengthExceeded 4 :: Either CT.TextException ())

    describe "binary isolate" $ do
        it "works" $ do
            bss <- runResourceT $ CL.sourceList (replicate 1000 "X")
                           C.$= CB.isolate 6
                           C.$$ CL.consume
            S.concat bss `shouldBe` "XXXXXX"
    describe "unbuffering" $ do
        it "works" $ do
            x <- runResourceT $ do
                let src1 = CL.sourceList [1..10 :: Int]
                (src2, ()) <- src1 C.$$+ CL.drop 5
                src2 C.$$+- CL.fold (+) 0
            x `shouldBe` sum [6..10]

    describe "operators" $ do
        it "only use =$=" $
            runIdentity
            (    CL.sourceList [1..10 :: Int]
              C.$$ CL.map (+ 1)
             C.=$  CL.map (subtract 1)
             C.=$  CL.mapM (return . (* 2))
             C.=$  CL.map (`div` 2)
             C.=$  CL.fold (+) 0
            ) `shouldBe` sum [1..10]
        it "only use =$" $
            runIdentity
            (    CL.sourceList [1..10 :: Int]
              C.$$ CL.map (+ 1)
              C.=$ CL.map (subtract 1)
              C.=$ CL.map (* 2)
              C.=$ CL.map (`div` 2)
              C.=$ CL.fold (+) 0
            ) `shouldBe` sum [1..10]
        it "chain" $ do
            x <-      CL.sourceList [1..10 :: Int]
                C.$=  CL.map (+ 1)
                C.$= CL.map (+ 1)
                C.$=  CL.map (+ 1)
                C.$= CL.map (subtract 3)
                C.$= CL.map (* 2)
                C.$$  CL.map (`div` 2)
                C.=$  CL.map (+ 1)
                C.=$  CL.map (+ 1)
                C.=$  CL.map (+ 1)
                C.=$  CL.map (subtract 3)
                C.=$  CL.fold (+) 0
            x `shouldBe` sum [1..10]


    describe "properly using binary file reading" $ do
        it "sourceFile" $ do
            x <- runResourceT $ CB.sourceFile "test/random" C.$$ CL.consume
            lbs <- L.readFile "test/random"
            L.fromChunks x `shouldBe` lbs

    describe "binary head" $ do
        let go lbs = do
                x <- CB.head
                case (x, L.uncons lbs) of
                    (Nothing, Nothing) -> return True
                    (Just y, Just (z, lbs'))
                        | y == z -> go lbs'
                    _ -> return False

        prop "works" $ \bss' ->
            let bss = map S.pack bss'
             in runIdentity $
                CL.sourceList bss C.$$ go (L.fromChunks bss)
    describe "binary takeWhile" $ do
        prop "works" $ \bss' ->
            let bss = map S.pack bss'
             in runIdentity $ do
                bss2 <- CL.sourceList bss C.$$ CB.takeWhile (>= 5) C.=$ CL.consume
                return $ L.fromChunks bss2 == L.takeWhile (>= 5) (L.fromChunks bss)
        prop "leftovers present" $ \bss' ->
            let bss = map S.pack bss'
             in runIdentity $ do
                result <- CL.sourceList bss C.$$ do
                    x <- CB.takeWhile (>= 5) C.=$ CL.consume
                    y <- CL.consume
                    return (S.concat x, S.concat y)
                let expected = S.span (>= 5) $ S.concat bss
                if result == expected
                    then return True
                    else error $ show (S.concat bss, result, expected)

    describe "binary dropWhile" $ do
        prop "works" $ \bss' ->
            let bss = map S.pack bss'
             in runIdentity $ do
                bss2 <- CL.sourceList bss C.$$ do
                    CB.dropWhile (< 5)
                    CL.consume
                return $ L.fromChunks bss2 == L.dropWhile (< 5) (L.fromChunks bss)

    describe "binary take" $ do
      let go n l = CL.sourceList l C.$$ do
          a <- CB.take n
          b <- CL.consume
          return (a, b)

      -- Taking nothing should result in an empty Bytestring
      it "nothing" $ do
        (a, b) <- runResourceT $ go 0 ["abc", "defg"]
        a              `shouldBe` L.empty
        L.fromChunks b `shouldBe` "abcdefg"

      it "normal" $ do
        (a, b) <- runResourceT $ go 4 ["abc", "defg"]
        a              `shouldBe` "abcd"
        L.fromChunks b `shouldBe` "efg"

      -- Taking exactly the data that is available should result in no
      -- leftover.
      it "all" $ do
        (a, b) <- runResourceT $ go 7 ["abc", "defg"]
        a `shouldBe` "abcdefg"
        b `shouldBe` []

      -- Take as much as possible.
      it "more" $ do
        (a, b) <- runResourceT $ go 10 ["abc", "defg"]
        a `shouldBe` "abcdefg"
        b `shouldBe` []

    describe "normalFuseLeft" $ do
        it "does not double close conduit" $ do
            x <- runResourceT $ do
                let src = CL.sourceList ["foobarbazbin"]
                src C.$= CB.isolate 10 C.$$ CL.head
            x `shouldBe` Just "foobarbazb"

    describe "binary" $ do
        prop "lines" $ \bss' -> runIdentity $ do
            let bss = map S.pack bss'
                bs = S.concat bss
                src = CL.sourceList bss
            res <- src C.$$ CB.lines C.=$ CL.consume
            return $ S8.lines bs == res

    describe "termination" $ do
        it "terminates early" $ do
            let src = forever $ C.yield ()
            x <- src C.$$ CL.head
            x `shouldBe` Just ()
        it "bracket" $ do
            ref <- I.newIORef (0 :: Int)
            let src = C.bracketP
                    (I.modifyIORef ref (+ 1))
                    (\() -> I.modifyIORef ref (+ 2))
                    (\() -> forever $ C.yield (1 :: Int))
            val <- C.runResourceT $ src C.$$ CL.isolate 10 C.=$ CL.fold (+) 0
            val `shouldBe` 10
            i <- I.readIORef ref
            i `shouldBe` 3
        it "bracket skipped if not needed" $ do
            ref <- I.newIORef (0 :: Int)
            let src = C.bracketP
                    (I.modifyIORef ref (+ 1))
                    (\() -> I.modifyIORef ref (+ 2))
                    (\() -> forever $ C.yield (1 :: Int))
                src' = CL.sourceList $ repeat 1
            val <- C.runResourceT $ (src' >> src) C.$$ CL.isolate 10 C.=$ CL.fold (+) 0
            val `shouldBe` 10
            i <- I.readIORef ref
            i `shouldBe` 0
        it "bracket + toPipe" $ do
            ref <- I.newIORef (0 :: Int)
            let src = C.bracketP
                    (I.modifyIORef ref (+ 1))
                    (\() -> I.modifyIORef ref (+ 2))
                    (\() -> forever $ C.yield (1 :: Int))
            val <- C.runResourceT $ src C.$$ CL.isolate 10 C.=$ CL.fold (+) 0
            val `shouldBe` 10
            i <- I.readIORef ref
            i `shouldBe` 3
        it "bracket skipped if not needed" $ do
            ref <- I.newIORef (0 :: Int)
            let src = C.bracketP
                    (I.modifyIORef ref (+ 1))
                    (\() -> I.modifyIORef ref (+ 2))
                    (\() -> forever $ C.yield (1 :: Int))
                src' = CL.sourceList $ repeat 1
            val <- C.runResourceT $ (src' >> src) C.$$ CL.isolate 10 C.=$ CL.fold (+) 0
            val `shouldBe` 10
            i <- I.readIORef ref
            i `shouldBe` 0

    describe "invariant violations" $ do
        it "leftovers without input" $ do
            ref <- I.newIORef []
            let add x = I.modifyIORef ref (x:)
                adder' = CI.NeedInput (\a -> liftIO (add a) >> adder') return
                adder = CI.ConduitM adder'
                residue x = CI.ConduitM $ CI.Leftover (CI.Done ()) x

            _ <- C.yield 1 C.$$ adder
            x <- I.readIORef ref
            x `shouldBe` [1 :: Int]
            I.writeIORef ref []

            _ <- C.yield 1 C.$$ (residue 2 >> residue 3) >> adder
            y <- I.readIORef ref
            y `shouldBe` [1, 2, 3]
            I.writeIORef ref []

            _ <- C.yield 1 C.$$ residue 2 >> (residue 3 >> adder)
            z <- I.readIORef ref
            z `shouldBe` [1, 2, 3]
            I.writeIORef ref []

    describe "sane yield/await'" $ do
        it' "yield terminates" $ do
            let is = [1..10] ++ undefined
                src [] = return ()
                src (x:xs) = C.yield x >> src xs
            x <- src is C.$$ CL.take 10
            x `shouldBe` [1..10 :: Int]
        it' "yield terminates (2)" $ do
            let is = [1..10] ++ undefined
            x <- mapM_ C.yield is C.$$ CL.take 10
            x `shouldBe` [1..10 :: Int]
        it' "yieldOr finalizer called" $ do
            iref <- I.newIORef (0 :: Int)
            let src = mapM_ (\i -> C.yieldOr i $ I.writeIORef iref i) [1..]
            src C.$$ CL.isolate 10 C.=$ CL.sinkNull
            x <- I.readIORef iref
            x `shouldBe` 10

    describe "upstream results" $ do
        it' "works" $ do
            let foldUp :: (b -> a -> b) -> b -> CI.Pipe l a Void u IO (u, b)
                foldUp f b = CI.awaitE >>= either (\u -> return (u, b)) (\a -> let b' = f b a in b' `seq` foldUp f b')
                passFold :: (b -> a -> b) -> b -> CI.Pipe l a a () IO b
                passFold f b = CI.await >>= maybe (return b) (\a -> let b' = f b a in b' `seq` CI.yield a >> passFold f b')
            (x, y) <- CI.runPipe $ mapM_ CI.yield [1..10 :: Int] CI.>+> passFold (+) 0 CI.>+>  foldUp (*) 1
            (x, y) `shouldBe` (sum [1..10], product [1..10])

    describe "input/output mapping" $ do
        it' "mapOutput" $ do
            x <- C.mapOutput (+ 1) (CL.sourceList [1..10 :: Int]) C.$$ CL.fold (+) 0
            x `shouldBe` sum [2..11]
        it' "mapOutputMaybe" $ do
            x <- C.mapOutputMaybe (\i -> if even i then Just i else Nothing) (CL.sourceList [1..10 :: Int]) C.$$ CL.fold (+) 0
            x `shouldBe` sum [2, 4..10]
        it' "mapInput" $ do
            xyz <- (CL.sourceList $ map show [1..10 :: Int]) C.$$ do
                (x, y) <- C.mapInput read (Just . show) $ ((do
                    x <- CL.isolate 5 C.=$ CL.fold (+) 0
                    y <- CL.peek
                    return (x :: Int, y :: Maybe Int)) :: C.Sink Int IO (Int, Maybe Int))
                z <- CL.consume
                return (x, y, concat z)

            xyz `shouldBe` (sum [1..5], Just 6, "678910")

    describe "left/right identity" $ do
        it' "left identity" $ do
            x <- CL.sourceList [1..10 :: Int] C.$$ CI.ConduitM CI.idP C.=$ CL.fold (+) 0
            y <- CL.sourceList [1..10 :: Int] C.$$ CL.fold (+) 0
            x `shouldBe` y
        it' "right identity" $ do
            x <- CI.runPipe $ mapM_ CI.yield [1..10 :: Int] CI.>+> (CI.injectLeftovers $ CI.unConduitM $ CL.fold (+) 0) CI.>+> CI.idP
            y <- CI.runPipe $ mapM_ CI.yield [1..10 :: Int] CI.>+> (CI.injectLeftovers $ CI.unConduitM $ CL.fold (+) 0)
            x `shouldBe` y

    describe "generalizing" $ do
        it' "works" $ do
            x <-     CI.runPipe
                   $ CI.sourceToPipe  (CL.sourceList [1..10 :: Int])
               CI.>+> CI.conduitToPipe (CL.map (+ 1))
               CI.>+> CI.sinkToPipe    (CL.fold (+) 0)
            x `shouldBe` sum [2..11]

    describe "withUpstream" $ do
        it' "works" $ do
            let src = mapM_ CI.yield [1..10 :: Int] >> return True
                fold f =
                    loop
                  where
                    loop accum =
                        CI.await >>= maybe (return accum) go
                      where
                        go a =
                            let accum' = f accum a
                             in accum' `seq` loop accum'
                sink = CI.withUpstream $ fold (+) 0
            res <- CI.runPipe $ src CI.>+> sink
            res `shouldBe` (True, sum [1..10])

    describe "iterate" $ do
        it' "works" $ do
            res <- CL.iterate (+ 1) (1 :: Int) C.$$ CL.isolate 10 C.=$ CL.fold (+) 0
            res `shouldBe` sum [1..10]

    describe "unwrapResumable" $ do
        it' "works" $ do
            ref <- I.newIORef (0 :: Int)
            let src0 = do
                    C.yieldOr () $ I.writeIORef ref 1
                    C.yieldOr () $ I.writeIORef ref 2
                    C.yieldOr () $ I.writeIORef ref 3
            (rsrc0, Just ()) <- src0 C.$$+ CL.head

            x0 <- I.readIORef ref
            x0 `shouldBe` 0

            (_, final) <- C.unwrapResumable rsrc0

            x1 <- I.readIORef ref
            x1 `shouldBe` 0

            final

            x2 <- I.readIORef ref
            x2 `shouldBe` 1

        it' "isn't called twice" $ do
            ref <- I.newIORef (0 :: Int)
            let src0 = do
                    C.yieldOr () $ I.writeIORef ref 1
                    C.yieldOr () $ I.writeIORef ref 2
            (rsrc0, Just ()) <- src0 C.$$+ CL.head

            x0 <- I.readIORef ref
            x0 `shouldBe` 0

            (src1, final) <- C.unwrapResumable rsrc0

            x1 <- I.readIORef ref
            x1 `shouldBe` 0

            Just () <- src1 C.$$ CL.head

            x2 <- I.readIORef ref
            x2 `shouldBe` 2

            final

            x3 <- I.readIORef ref
            x3 `shouldBe` 2

        it' "source isn't used" $ do
            ref <- I.newIORef (0 :: Int)
            let src0 = do
                    C.yieldOr () $ I.writeIORef ref 1
                    C.yieldOr () $ I.writeIORef ref 2
            (rsrc0, Just ()) <- src0 C.$$+ CL.head

            x0 <- I.readIORef ref
            x0 `shouldBe` 0

            (src1, final) <- C.unwrapResumable rsrc0

            x1 <- I.readIORef ref
            x1 `shouldBe` 0

            () <- src1 C.$$ return ()

            x2 <- I.readIORef ref
            x2 `shouldBe` 0

            final

            x3 <- I.readIORef ref
            x3 `shouldBe` 1
    describe "injectLeftovers" $ do
        it "works" $ do
            let src = mapM_ CI.yield [1..10 :: Int]
                conduit = CI.injectLeftovers $ CI.unConduitM $ C.awaitForever $ \i -> do
                    js <- CL.take 2
                    mapM_ C.leftover $ reverse js
                    C.yield i
            res <- CI.ConduitM (src CI.>+> CI.injectLeftovers conduit) C.$$ CL.consume
            res `shouldBe` [1..10]
    describe "up-upstream finalizers" $ do
        it "pipe" $ do
            let p1 = CI.await >>= maybe (return ()) CI.yield
                p2 = idMsg "p2-final"
                p3 = idMsg "p3-final"
                idMsg msg = CI.addCleanup (const $ tell [msg]) $ CI.awaitForever CI.yield
                printer = CI.awaitForever $ lift . tell . return . show
                src = mapM_ CI.yield [1 :: Int ..]
            let run' p = execWriter $ CI.runPipe $ printer CI.<+< p CI.<+< src
            run' (p1 CI.<+< (p2 CI.<+< p3)) `shouldBe` run' ((p1 CI.<+< p2) CI.<+< p3)
        it "conduit" $ do
            let p1 = C.await >>= maybe (return ()) C.yield
                p2 = idMsg "p2-final"
                p3 = idMsg "p3-final"
                idMsg msg = C.addCleanup (const $ tell [msg]) $ C.awaitForever C.yield
                printer = C.awaitForever $ lift . tell . return . show
                src = CL.sourceList [1 :: Int ..]
            let run' p = execWriter $ src C.$$ p C.=$ printer
            run' ((p3 C.=$= p2) C.=$= p1) `shouldBe` run' (p3 C.=$= (p2 C.=$= p1))
    describe "monad transformer laws" $ do
        it "transPipe" $ do
            let source = CL.sourceList $ replicate 10 ()
            let tell' x = tell [x :: Int]

            let replaceNum1 = C.awaitForever $ \() -> do
                    i <- lift get
                    lift $ (put $ i + 1) >> (get >>= lift . tell')
                    C.yield i

            let replaceNum2 = C.awaitForever $ \() -> do
                    i <- lift get
                    lift $ put $ i + 1
                    lift $ get >>= lift . tell'
                    C.yield i

            x <- runWriterT $ source C.$$ C.transPipe (`evalStateT` 1) replaceNum1 C.=$ CL.consume
            y <- runWriterT $ source C.$$ C.transPipe (`evalStateT` 1) replaceNum2 C.=$ CL.consume
            x `shouldBe` y
    describe "text decode" $ do
        it' "doesn't throw runtime exceptions" $ do
            let x = runIdentity $ runExceptionT $ C.yield "\x89\x243" C.$$ CT.decode CT.utf8 C.=$ CL.consume
            case x of
                Left _ -> return ()
                Right t -> error $ "This should have failed: " ++ show t
    describe "iterM" $ do
        prop "behavior" $ \l -> monadicIO $ do
            let counter ref = CL.iterM (const $ liftIO $ M.modifyMVar_ ref (\i -> return $! i + 1))
            v <- run $ do
                ref <- M.newMVar 0
                CL.sourceList l C.$= counter ref C.$$ CL.mapM_ (const $ return ())
                M.readMVar ref

            assert $ v == length (l :: [Int])
        prop "mapM_ equivalence" $ \l -> monadicIO $ do
            let runTest h = run $ do
                    ref <- M.newMVar (0 :: Int)
                    let f = action ref
                    s <- CL.sourceList (l :: [Int]) C.$= h f C.$$ CL.fold (+) 0
                    c <- M.readMVar ref

                    return (c, s)

                action ref = const $ liftIO $ M.modifyMVar_ ref (\i -> return $! i + 1)
            (c1, s1) <- runTest CL.iterM
            (c2, s2) <- runTest (\f -> CL.mapM (\a -> f a >>= \() -> return a))

            assert $ c1 == c2
            assert $ s1 == s2

    describe "generalizing" $ do
        it "works" $ do
            let src :: Int -> C.Source IO Int
                src i = CL.sourceList [1..i]
                sink :: C.Sink Int IO Int
                sink = CL.fold (+) 0
            res <- C.yield 10 C.$$ C.awaitForever (C.toProducer . src) C.=$ (C.toConsumer sink >>= C.yield) C.=$ C.await
            res `shouldBe` Just (sum [1..10])

    describe "sinkCacheLength" $ do
        it' "works" $ C.runResourceT $ do
            lbs <- liftIO $ L.readFile "test/main.hs"
            (len, src) <- CB.sourceLbs lbs C.$$ CB.sinkCacheLength
            lbs' <- src C.$$ CB.sinkLbs
            liftIO $ do
                fromIntegral len `shouldBe` L.length lbs
                lbs' `shouldBe` lbs
                fromIntegral len `shouldBe` L.length lbs'

    describe "Data.Conduit.Binary.mapM_" $ do
        prop "telling works" $ \bytes ->
            let lbs = L.pack bytes
                src = CB.sourceLbs lbs
                sink = CB.mapM_ (tell . return . S.singleton)
                bss = execWriter $ src C.$$ sink
             in L.fromChunks bss == lbs

    describe "passthroughSink" $ do
        it "works" $ do
            ref <- I.newIORef (-1)
            let sink = CL.fold (+) (0 :: Int)
                conduit = C.passthroughSink sink (I.writeIORef ref)
                input = [1..10]
            output <- mapM_ C.yield input C.$$ conduit C.=$ CL.consume
            output `shouldBe` input
            x <- I.readIORef ref
            x `shouldBe` sum input
        it "does nothing when downstream does nothing" $ do
            ref <- I.newIORef (-1)
            let sink = CL.fold (+) (0 :: Int)
                conduit = C.passthroughSink sink (I.writeIORef ref)
                input = [undefined]
            mapM_ C.yield input C.$$ conduit C.=$ return ()
            x <- I.readIORef ref
            x `shouldBe` (-1)

    describe "mtl instances" $ do
        it "ErrorT" $ do
            let src = flip catchError (const $ C.yield 4) $ do
                    lift $ return ()
                    C.yield 1
                    lift $ return ()
                    C.yield 2
                    lift $ return ()
                    () <- throwError DummyError
                    lift $ return ()
                    C.yield 3
                    lift $ return ()
            (src C.$$ CL.consume) `shouldBe` Right [1, 2, 4 :: Int]

    describe "finalizers" $ do
        it "promptness" $ do
            imsgs <- I.newIORef []
            let add x = liftIO $ do
                    msgs <- I.readIORef imsgs
                    I.writeIORef imsgs $ msgs ++ [x]
                src' = C.bracketP
                    (add "acquire")
                    (const $ add "release")
                    (const $ C.addCleanup (const $ add "inside") (mapM_ C.yield [1..5]))
                src = do
                    src' C.$= CL.isolate 4
                    add "computation"
                sink = CL.mapM (\x -> add (show x) >> return x) C.=$ CL.consume

            res <- C.runResourceT $ src C.$$ sink

            msgs <- I.readIORef imsgs
            -- FIXME this would be better msgs `shouldBe` words "acquire 1 2 3 4 inside release computation"
            msgs `shouldBe` words "acquire 1 2 3 4 release inside computation"

            res `shouldBe` [1..4 :: Int]

        it "left associative" $ do
            imsgs <- I.newIORef []
            let add x = liftIO $ do
                    msgs <- I.readIORef imsgs
                    I.writeIORef imsgs $ msgs ++ [x]
                p1 = C.bracketP (add "start1") (const $ add "stop1") (const $ add "inside1" >> C.yield ())
                p2 = C.bracketP (add "start2") (const $ add "stop2") (const $ add "inside2" >> C.await >>= maybe (return ()) C.yield)
                p3 = C.bracketP (add "start3") (const $ add "stop3") (const $ add "inside3" >> C.await)

            res <- C.runResourceT $ (p1 C.$= p2) C.$$ p3
            res `shouldBe` Just ()

            msgs <- I.readIORef imsgs
            msgs `shouldBe` words "start3 inside3 start2 inside2 start1 inside1 stop3 stop2 stop1"

        it "right associative" $ do
            imsgs <- I.newIORef []
            let add x = liftIO $ do
                    msgs <- I.readIORef imsgs
                    I.writeIORef imsgs $ msgs ++ [x]
                p1 = C.bracketP (add "start1") (const $ add "stop1") (const $ add "inside1" >> C.yield ())
                p2 = C.bracketP (add "start2") (const $ add "stop2") (const $ add "inside2" >> C.await >>= maybe (return ()) C.yield)
                p3 = C.bracketP (add "start3") (const $ add "stop3") (const $ add "inside3" >> C.await)

            res <- C.runResourceT $ p1 C.$$ (p2 C.=$ p3)
            res `shouldBe` Just ()

            msgs <- I.readIORef imsgs
            msgs `shouldBe` words "start3 inside3 start2 inside2 start1 inside1 stop3 stop2 stop1"

        describe "dan burton's associative tests" $ do
            let tellLn = tell . (++ "\n")
                finallyP fin = CI.addCleanup (const fin)
                printer = CI.awaitForever $ lift . tellLn . show
                idMsg msg = finallyP (tellLn msg) CI.idP
                takeP 0 = return ()
                takeP n = CI.awaitE >>= \ex -> case ex of
                  Left _u -> return ()
                  Right i -> CI.yield i >> takeP (pred n)

                testPipe p = execWriter $ runPipe $ printer <+< p <+< CI.sourceList ([1..] :: [Int])

                p1 = takeP (1 :: Int)
                p2 = idMsg "foo"
                p3 = idMsg "bar"

                (<+<) = (CI.<+<)
                runPipe = CI.runPipe

                test1L = testPipe $ (p1 <+< p2) <+< p3
                test1R = testPipe $ p1 <+< (p2 <+< p3)

                _test2L = testPipe $ (p2 <+< p1) <+< p3
                _test2R = testPipe $ p2 <+< (p1 <+< p3)

                test3L = testPipe $ (p2 <+< p3) <+< p1
                test3R = testPipe $ p2 <+< (p3 <+< p1)

                verify testL testR p1' p2' p3'
                  | testL == testR = return () :: IO ()
                  | otherwise = error $ unlines
                    [ "FAILURE"
                    , ""
                    , "(" ++ p1' ++ " <+< " ++ p2' ++ ") <+< " ++ p3'
                    , "------------------"
                    , testL
                    , ""
                    , p1' ++ " <+< (" ++ p2' ++ " <+< " ++ p3' ++ ")"
                    , "------------------"
                    , testR
                    ]

            it "test1" $ verify test1L test1R "p1" "p2" "p3"
            -- FIXME this is broken it "test2" $ verify test2L test2R "p2" "p1" "p3"
            it "test3" $ verify test3L test3R "p2" "p3" "p1"

    describe "Data.Conduit.Lift" $ do
        it "execStateC" $ do
            let sink = C.execStateC 0 $ CL.mapM_ $ modify . (+)
                src = mapM_ C.yield [1..10 :: Int]
            res <- src C.$$ sink
            res `shouldBe` sum [1..10]

        it "execWriterC" $ do
            let sink = C.execWriterC $ CL.mapM_ $ tell . return
                src = mapM_ C.yield [1..10 :: Int]
            res <- src C.$$ sink
            res `shouldBe` [1..10]

        it "runErrorC" $ do
            let sink = C.runErrorC $ do
                    x <- C.catchErrorC (lift $ throwError "foo") return
                    return $ x ++ "bar"
            res <- return () C.$$ sink
            res `shouldBe` Right ("foobar" :: String)

        it "runMaybeC" $ do
            let src = void $ C.runMaybeC $ do
                    C.yield 1
                    () <- lift $ MaybeT $ return Nothing
                    C.yield 2
                sink = CL.consume
            res <- src C.$$ sink
            res `shouldBe` [1 :: Int]

    describe "exception handling" $ do
        it "catchC" $ do
            ref <- I.newIORef 0
            let src = do
                    C.catchC (CB.sourceFile "some-file-that-does-not-exist") onErr
                    C.handleC onErr $ CB.sourceFile "conduit.cabal"
                onErr :: MonadIO m => IOException -> m ()
                onErr _ = liftIO $ I.modifyIORef ref (+ 1)
            contents <- L.readFile "conduit.cabal"
            res <- C.runResourceT $ src C.$$ CB.sinkLbs
            res `shouldBe` contents
            errCount <- I.readIORef ref
            errCount `shouldBe` (1 :: Int)
        it "tryC" $ do
            ref <- I.newIORef undefined
            let src = do
                    res1 <- C.tryC $ CB.sourceFile "some-file-that-does-not-exist"
                    res2 <- C.tryC $ CB.sourceFile "conduit.cabal"
                    liftIO $ I.writeIORef ref (res1, res2)
            contents <- L.readFile "conduit.cabal"
            res <- C.runResourceT $ src C.$$ CB.sinkLbs
            res `shouldBe` contents
            exc <- I.readIORef ref
            case exc :: (Either IOException (), Either IOException ()) of
                (Left _, Right ()) ->
                    return ()
                _ -> error $ show exc

    describe "sequenceSources" $ do
        it "works" $ do
            let src1 = mapM_ C.yield [1, 2, 3 :: Int]
                src2 = mapM_ C.yield [3, 2, 1]
                src3 = mapM_ C.yield $ repeat 2
                srcs = C.sequenceSources $ Map.fromList
                    [ (1 :: Int, src1)
                    , (2, src2)
                    , (3, src3)
                    ]
            res <- srcs C.$$ CL.consume
            res `shouldBe`
                [ Map.fromList [(1, 1), (2, 3), (3, 2)]
                , Map.fromList [(1, 2), (2, 2), (3, 2)]
                , Map.fromList [(1, 3), (2, 1), (3, 2)]
                ]
    describe "zipSink" $ do
        it "zip equal-sized" $ do
            x <- runResourceT $
                    CL.sourceList [1..100] C.$$
                    C.sequenceSinks [ CL.fold (+) 0,
                                   (`mod` 101) <$> CL.fold (*) 1 ]
            x `shouldBe` [5050, 100 :: Integer]

        it "zip distinct sizes" $ do
            let sink = C.getZipSink $
                        (*) <$> C.ZipSink (CL.fold (+) 0)
                            <*> C.ZipSink (Data.Maybe.fromJust <$> C.await)
            x <- C.runResourceT $ CL.sourceList [100,99..1] C.$$ sink
            x `shouldBe` (505000 :: Integer)

    ES.spec
    ZipConduit.spec

it' :: String -> IO () -> Spec
it' = it

data DummyError = DummyError
    deriving (Show, Eq)
instance Error DummyError
