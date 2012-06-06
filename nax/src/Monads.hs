module Monads where

import Data.IORef(newIORef,readIORef,writeIORef,IORef)
import System.IO(fixIO,hClose,hFlush,stdout)
-- import qualified System.IO.Error as Err -- Deprecated
import qualified Control.Exception         -- Use this instead
import System.IO.Unsafe(unsafePerformIO)
import Text.Parsec.Pos(SourcePos,newPos)

import Names(SourcePos,noPos)

tryIO :: IO a -> IO (Either IOError a)
tryIO = Control.Exception.try
--------------------------------------
-- Monads for computing values
-- Note that values include delayed computations 
-- which are FIO computations

data Exception x
   = Ok x
   | Fail SourcePos  -- Source Location of Error
          Int        -- Severity or level of error
          String     -- kind of error
          String     -- message

instance Monad Exception where
  return x = Ok x
  (>>=) (Ok x) f = f x
  (>>=) (Fail loc n k s) f  = Fail loc n k s
  fail s = Fail noPos 0 "" s

instance Functor Exception where
  fmap f (Ok x) = Ok (f x)
  fmap f (Fail loc n k s) = Fail loc n k s

--------------------------------------------
-- FIO  = IO with catchable failure

newtype FIO x = FIO(IO (Exception x))
unFIO (FIO x) = x

instance Monad FIO where
  fail s = failFIO noPos 0 s
  return x = FIO(return(Ok x))
  (>>=) (FIO a) g = FIO w
    where w = do { x <- a
                 ; case x of
                    Ok z -> unFIO(g z)
                    Fail loc n k s -> return(Fail loc n k s)}

instance Functor FIO where
  fmap f (FIO x) = FIO(fmap (fmap f) x)

failFIO loc n s = FIO(return(Fail loc n "" s))

failFIOwith loc n failureTag s = FIO(return(Fail loc n failureTag s))

-- XXX: what are these handlers and what do their names mean ???
--
-- This one appears to take a (P)redicate 'p' and an error handler 'f'
-- which is called if the computation 'FIO x' fails with an error
-- level less than 'm' and an error type 'k' for which the predicate
-- 'p' holds.
handleP :: (String -> Bool) -> Int -> FIO a ->
           (SourcePos -> String -> FIO a) -> FIO a
handleP p m (FIO x) f = FIO w
  where w = do { a <- x
               ; case a of
                   Fail loc n k s ->
                       if (m > n) && (p k)
                          then unFIO(f loc s)
                          else return(Fail loc n k s)
                   ok -> return(ok)}

handleS :: FIO a -> (SourcePos -> String -> FIO a) -> FIO a
handleS comp f = handleP (const True) 100 comp f

handle = handleP (\ _ -> True)

tryAndReport :: FIO a -> (SourcePos -> String -> FIO a) -> FIO a
tryAndReport (FIO x) f = FIO w
  where w = do { a <- x
               ; case a of
                   Fail loc n k s -> unFIO(f loc s)
                   ok -> return(ok)}


runFIO :: FIO x -> (SourcePos -> Int -> String -> IO x) -> IO x
runFIO (FIO x) f = do { a <- x
                      ; case a of
                          Ok z -> return z
                          Fail loc n k s -> f loc n s }

-- for testing only
instance Show a => Show (FIO a) where
  show x = show (unsafePerformIO(runFIO x errf))
             where errf pos i mess = fail mess


fixFIO :: (a -> FIO a) -> FIO a
fixFIO f = FIO(fixIO (unFIO . unRight f))
  where unRight f ~(Ok x) = f x
    --  unRight f other = FIO(return other)
    -- unreachable because of lazy ~pattern

fio :: IO x -> FIO x
fio x = FIO $ do result <- tryIO x 
                 case result of
                   Left err  -> return (Fail noPos 0 "IO error" ("\n"++show err))
                   Right ans -> return (Ok ans)

write = fio . putStr
writeln = fio . putStrLn

readln :: String -> FIO String
readln prompt = fio (do {putStr prompt; hFlush stdout; getLine})

nextInteger = do { n <- readIORef counter; writeIORef counter (n+1); return n }
resetNext m = writeIORef counter m
next = fio nextInteger

fresh = unique "_x"
unique s = do { n <- next; return (s++show n)}

-- ???: why unsafePerformIO ?
counter :: IORef Integer
counter = unsafePerformIO(newIORef 0)

newRef x = fio(newIORef x)
readRef r = fio(readIORef r)
writeRef x r = fio(writeIORef x r)

-------------------------------------------------------------
-- A lifted monad, is a monad that returns a maybe object
-- This gives two levels of failure
--   fail s    non recoverable
--   none      testable (i.e. return Nothing in the original monad)

newtype Lifted f x = Lift (f(Maybe x))
instance Monad f => Monad (Lifted f) where
  return x = Lift(return(Just x))
  (Lift comp) >>= g = Lift comp2
    where comp2 = do { ans <- comp
                     ; case ans of
                         Nothing -> return Nothing
                         Just a -> case g a of
                                    (Lift comp3) -> comp3 }
  fail s = Lift(fail s) 

none :: Monad m => Lifted m a
none = Lift(return Nothing)

runLifted :: Monad m => Lifted m a -> m b -> (a -> m b) -> m b
runLifted (Lift x) y f = 
   do { ans <- x
      ; case ans of
          Nothing -> y
          Just x -> f x }
          
lifted :: Monad m => m a -> Lifted m a
lifted comp = Lift(do{ x <- comp; return(Just x)})

-----------------------------------------------

fmapM :: Monad m => (a -> m b) -> m a -> m b
fmapM f comp = do { x <- comp; f x;}

when :: Monad m => Bool -> m () -> m ()
when x  comp = if x then comp else return ()

whenM :: Monad m => m Bool -> m b -> [Char] -> m b
whenM test x s = do { b <- test; if b then x else error s}

ifM :: Monad m => m Bool -> m b -> m b -> m b
ifM test x y = do { b <- test; if b then x else y }

anyM :: Monad m => (b -> m Bool) -> [b] -> m Bool
anyM p xs = do { bs <- mapM p xs; return(or bs) }


allM :: Monad m => (b -> m Bool) -> [b] -> m Bool
allM p xs = do { bs <- mapM p xs; return(and bs) }


orM :: Monad m => m Bool -> m Bool -> m Bool
orM x y = do { a <- x; b <- y; return (a || b) }

maybeM :: Monad m => m(Maybe a) -> (a -> m b) -> (m b) -> m b
maybeM mma f mb = do { x <- mma; case x of { Nothing -> mb ; Just x -> f x }}


elemByM f x [] = return False
elemByM f x (y:ys) = ifM (f x y) (return True) (elemByM f x ys)

unionByM f xs [] = return xs
unionByM f xs (y:ys) = 
   ifM (elemByM f y xs) (unionByM f xs ys) (unionByM f (y:xs) ys)
             