{-# LANGUAGE StandaloneDeriving, DeriveDataTypeable, GeneralizedNewtypeDeriving,
  NamedFieldPuns #-}
module Language.SepPP.TypeCheck where

import Language.SepPP.Syntax
import Unbound.LocallyNameless hiding (Con,isTerm,Val,join)
import Unbound.LocallyNameless.Ops(unsafeUnbind)


import Data.Typeable
import Control.Monad.Reader hiding (join)
import Control.Monad.Error hiding (join)
import Control.Exception(Exception)
import Control.Applicative

-- * The typechecking monad

newtype TCMonad a =
  TCMonad { runTCMonad :: ReaderT Env (FreshMT (ErrorT TypeError IO)) a }
  deriving (Fresh, Functor, Monad, MonadReader Env, MonadError TypeError, MonadIO)


typecheck :: Module -> IO (Either TypeError ())
typecheck mod = do
  runErrorT $ runFreshMT $ runReaderT (runTCMonad (typecheckModule mod)) emptyEnv

-- ** The Environment

-- The typing context contains a mapping from variable names to types, with
-- an additional boolean indicating if it the variable is a value.
data Env = Env { gamma :: [(TName,(Term,Bool))] }
emptyEnv = Env {gamma = []}

-- | Add a new binding to an environment
extendEnv n ty isVal  e@(Env {gamma}) = e{gamma = (n,(ty,isVal)):gamma}


-- Functions for working in the environment
lookupBinding :: TName -> TCMonad (Term,Bool)
lookupBinding n = do
  env <- asks gamma
  maybe (err $ "Can't find variable " ++ show n ++ "\n" ++ show env) return (lookup n env)
extendBinding :: TName -> Term -> Bool -> TCMonad a -> TCMonad a
extendBinding n ty isVal m = do
  local (extendEnv n ty isVal) m


-- ** Error handling

data TypeError = TypeError String deriving (Typeable,Show)
instance Error TypeError where
  strMsg s = TypeError s
  noMsg = TypeError "<gack>"
instance Exception TypeError

err msg = throwError (TypeError msg)


-- * Running the typechecker.

-- | Typecheck an entire module
typecheckModule (Module n decls) = do
  checkDefs decls
  liftIO $ putStrLn "Typecheck passed"
  return ()

-- | Typecheck a single definition
checkDef (ProofDecl nm theorem proof) = do
  lk <- predSynth theorem
  isLK <- lkJudgment lk
  unless isLK $
         err $ "Theorem is not a well-formed logical kind " ++ show nm

  proofAnalysis proof theorem
  return (nm,theorem,False)

checkDef (ProgDecl nm ty prog) = do
  err $ "Can't typecheck program " ++ show nm

checkDef (DataDecl nm _ _) = do
  err $ "Can't typecheck data decl " ++ show nm



checkDefs [] = return ()
checkDefs (d:ds) = do
  (n,ty,v) <- checkDef d
  extendBinding n ty v (checkDefs ds)




-- The S, G |- val t judgement.
valJudgment (Var v) = do
  (_,v) <- lookupBinding v
  return v
valJudgment Type = return True
valJudgment (Pi _ _ ) = return True
valJudgment (Lambda _ _ _ ) = return True
valJudgment (Rec _ ) = return True
-- valJudgement Nat = True
valJudgment t@(App _ _ _ ) =
  case splitApp t of
    ((Con _):args) -> do
       vals <- mapM valJudgment args
       return $ and vals
    _ -> return False


-- * Judgements on proof fragment

-- The S,G |- LK : LogicalKind judgment
lkJudgment (Formula _ ) = return True
lkJudgment (Forall binding) = do
  ((n,Embed ty),body) <- unbind binding
  unless (isA ty)$
    err "Expecting the classifier for a logical kind argument to be syntax class 'A'"
  extendBinding n ty False (lkJudgment body)

guardLK t = do
  lk <- lkJudgment t
  unless lk $ err $ show t ++ " is not a valid logical kind."


-- The S,G |- P : LK judgment
predSynth (Parens p) = predSynth p
predSynth (Forall binding) = do
  ((n,Embed t),body) <- unbind binding
  -- We need to do a syntactic case-split on ty. Going to use backtracking for now.
  case t of
    Formula i -> do  -- Pred_Forall3 rule
           form <- extendBinding n t False (predSynth body)
           (Formula j) <- guardFormula form
           return (Formula (max (i+1) j))
    (Forall binding') -> do -- Pred_Forall4 rule
           guardLK t
           form <- extendBinding n t False (predSynth body)
           guardFormula form
    _ -> do
      -- TODO: Handle the case where the type is a pred.

      -- * ty is a term or pred. just handling term for now
      ty <- typeSynth t
      unless (ty `aeq` Type) $
             err $ "Expecting a type for " ++ show ty


      form <- extendBinding n ty False (predSynth body)
      guardFormula form



  where guardFormula t@(Formula i) = return t
        guardFormula _ = err "Not a formula"


predSynth (Equal t0 t1) = do -- Pred_K_Eq rule
  ty0 <- typeSynth t0
  ty1 <- typeSynth t1
  -- TODO: Do we need to check to see that ty0 and t1 : Type?
  return (Formula 0)

predSynth (Terminates t) = do -- Pred_Terminates rule
  typeSynth t
  return (Formula 0) -- TODO: Should this really be 0?

predSynth (Lambda Form Static binding) = do -- Pred_Lam rule
  ((n,Embed ty),body) <- unbind binding
  -- First Premise
  unless (isW ty) $
         err $ show ty ++ " is not in the 'W' syntactic class."
  -- Second Premise
  form <- extendBinding n ty False (predSynth body)
  lk <- lkJudgment form
  unless lk $ err (show form ++ " is not a valid logical kind.")

  return (Forall (bind (n,Embed ty) form))


predSynth (App t0 Static t1) = do -- Pred_App rule
  form <- predSynth t0
  case form of
    Forall binding -> do
              ((n,ty),body) <- unbind binding
              guardLK body
              typeAnalysis t1 ty
              return $ subst n t1 body
    _ -> err ("Can't apply non-quantified predicate " ++ show t0)


predSynth p = do
  err $ show p ++ " is not a valid predicate."


proofSynth (Var x) = do         -- Prf_Var
  (ty,_) <- lookupBinding x
  requireA ty
  pty <- predSynth ty
  requireQ pty
  return ty

-- TODO: Waiting for Harley to split the forall rule before implementing it.
proofSynth (App p Static b) = do
  pty <- predSynth p
  case pty of
    Forall binding -> do
             ((n,Embed ty),body) <- unbind binding
             requireB ty
             requirePred body
             bty <- bAnalysis b ty
             return $ subst n b body

proofSynth (Parens p) = proofSynth p
proofSynth (Ann p pred) = do
  proofAnalysis p pred
  return pred
proofSynth t = err $ "TODO: proofSynth: " ++ show t



-- FIXME: This is a stopgap, while waiting on the new split rules for
-- Prf_Forall.  FIXME: The static/dynamic argument should always be static
-- (since this is a proof) but the concrete syntax doesn't handle this right, it
-- always requires static/dynamic annotations, even if
proofAnalysis (Lambda Form _ pfBinding)
              out@(Forall predBinding) = do -- Prf_Forall.

  Just ((proofName,Embed pfTy),pfBody,(predName,Embed predTy),predBody) <-
    unbind2  pfBinding predBinding
  -- ((predName,Embed predTy),predBody) <- unbind predBinding

  -- unless (pfTy `aeq` predTy  && proofName == predName) $
  --        err "PA domerr"

  requireQ pfTy

  -- Whether the var should be marked value or not is sort of up in the air...
  extendBinding proofName pfTy False (proofAnalysis pfBody predBody)
  return out


proofAnalysis (Parens p) eq = proofAnalysis p eq
proofAnalysis p (Parens eq) = proofAnalysis p eq
proofAnalysis (Join _ _) eq@(Equal t0 t1) = do
  typeSynth t0
  typeSynth t1
  -- FIXME: Need to define operational semantics.
  join t0 t1
  return eq

proofAnalysis p pred = do
  err $ "TODO: proofAnalysis: " ++ show  (Ann p pred)



-- * Judgements on program fragment
typeSynth (Parens t) = typeSynth t
typeSynth Type = return Type
typeSynth (Var n) = do
  (ty,_) <- lookupBinding n
  return ty
typeSynth t = err $ "TODO: typeSynth: " ++ show t


typeAnalysis t ty = err "TODO: typeAnalysis"


-- FIXME: This needs to try to synthesize (analyze) a type for everything in the b
-- syntactic class, not just terms.
bSynth t = typeSynth t
bAnalysis t = typeAnalysis t


-- Syntactic class predicates (TODO)
isA t = isTerm t || isPred t
isB t = isTerm t || isPred t || isLK t

isW Type = True
isW (Formula _) = True
isW _ = False

isQ Type = True
isQ (Formula _) = True
isQ t = isLK t


isLK (Formula _) = True
isLK (Forall binding) = isA ty && isLK body
  where ((n,Embed ty),body) = unsafeUnbind binding
isLK _ = False


isPred (Var x) = True
isPred (Lambda Form Static binding) = isA ty && isPred body
  where ((n,Embed ty),body) = unsafeUnbind binding
isPred (App t0 Static t1) = isPred t0 && is_a t1
isPred (Forall binding) = isB ty && isPred body
  where ((n,Embed ty),body) = unsafeUnbind binding
isPred (Equal t0 t1) = isTerm t0 && isTerm t1
isPred (IndLT t0 t1) = isTerm t0 && isTerm t1
isPred (Terminates t) = isTerm t
isPred (Ann p t) = isPred p && isLK t
isPred (Parens p) = isPred p
isPred _ = False


isProof (Var x) = True
isProof (Lambda Form  Static binding) = isB ty && isProof body
  where ((n,Embed ty),body) = unsafeUnbind binding
isProof (App t0 Static t1) = isProof t0 && is_b t1
isProof (Join _ _) = True
isProof (Conv p ps binding) = isProof p &&
                              and [is_q t | (_,t) <- ps] &&
                              is_a body
  where (_,body) = unsafeUnbind binding
isProof (Val t) = isTerm t
isProof (Ord t0 t1) = isTerm t0 && isTerm t1
isProof (Case scrutinee cpf (Just tpf) alts) =
  isTerm scrutinee && and (map chkAlt alts)
 where chkAlt a = let ((c,as),alt) = unsafeUnbind a in isProof alt
isProof (TerminationCase scrutinee binding) =
    isTerm scrutinee && isProof p0 && isProof p1
  where (pf,(p0,p1)) = unsafeUnbind binding

isProof (Ind binding) = isTerm ty &&  isProof body
  where ((f,(n,Embed ty),opf),body) = unsafeUnbind binding
isProof (Contra p) = isProof p
isProof (ContraAbort p0 p1) = isProof p0 && isProof p1
isProof (Ann p pred) = isProof p && isPred pred
isProof (Parens p) = isProof p
isProof t = False



isTerm (Var _) = True
isTerm (Con _) = True
isTerm Type = True
isTerm (Pi _ binding) = isA ty && isTerm body
  where ((n,Embed ty),body) = unsafeUnbind binding
isTerm (Lambda Program _ binding) = isA ty && isTerm body
  where ((n,Embed ty),body) = unsafeUnbind binding
isTerm (Conv t ts binding) = isTerm t &&
                             and [is_q t | (_,t) <- ts] &&
                             isTerm body
  where (_,body) = unsafeUnbind binding
isTerm (App t0 _ t1) = isTerm t0 && is_a t1
isTerm (Abort t) = isTerm t
isTerm (Rec binding) = isTerm ty &&  isTerm body
  where ((f,(n,Embed ty)),body) = unsafeUnbind binding
isTerm (Ann t0 t1) = isTerm t0 && isTerm t1
isTerm (Parens t) = isTerm t
isTerm t = False


is_a t = isTerm t || isProof t || isLK t
is_b t = isTerm t || isProof t || isPred t

is_q (Equal t0 t1) = isTerm t0 && isTerm t1
is_q t = isProof t


-- Lifting predicates to the TC monad, where False == failure
requireA = require isA "A"
requireQ = require isQ "Q"
requireB = require isB "B"
requirePred = require isPred "P"


require p cls (Var n) = do
  (v,_) <- lookupBinding n
  require p cls v

require p cls t =
  unless (p t) $
         err $ show t ++ " is not the proper syntactic class (" ++
               cls ++ ")."





-- Placeholder for op. semantics
join t1 t2 = unless (t1 `aeq` t2) $ err "Terms not joinable"