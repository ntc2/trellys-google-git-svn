{-# LANGUAGE TemplateHaskell, ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses, FlexibleContexts, UndecidableInstances, GADTs, TypeOperators, TypeFamilies, RankNTypes, PackageImports #-}
module Language.SepPP.Eval where

import Language.SepPP.Syntax(EExpr(..),erase)
import Language.SepPP.PrettyPrint
import Language.SepPP.TCUtils
import Language.SepPP.Options

import Generics.RepLib hiding (Con(..))
import Unbound.LocallyNameless hiding (Con(..))
-- import Control.Monad((>=>))
import "mtl" Control.Monad.Trans
import Control.Applicative
import Control.Monad
import "mtl" Control.Monad.Error
import Text.PrettyPrint(render, text,(<+>),($$))

-- compile-time configuration: should reduction steps be logged
debugReductions = False

eval steps t = do
  t' <- erase t
  -- emit $ "Reducing" <++> t'
  evalErased steps t'

evalErased steps t = reduce steps t (\_ tm -> return tm)

logReduce t t' = do
  lr <- getOptShowReductions
  when lr $ do
    emit $ ("reduced" $$$ t $$$ "to" $$$ t')
    emit $  "===" <++> "==="

reduce :: Integer -> EExpr -> (Integer -> EExpr -> TCMonad EExpr) -> TCMonad EExpr
reduce 0 t k = k 0 t
reduce steps v@(EVar n) k = do
     d <- lookupDef (translate n)
     case d of
       Just def -> do
              t' <- erase def
              logReduce v t'
              reduce (steps - 1) t' k
       Nothing -> do
               when debugReductions $ emit ("Can't reduce variable" <++> v)
               k steps v
reduce steps t@(ECon _) k = k steps t

reduce steps tm@(EApp t1 t2) k = do
   -- emit $ "Reducing term" $$$ disp tm
   reduce steps t1 k'
  where k' 0 t1' = k 0 (EApp t1' t2)
        k' steps t1'@(ELambda binding) = do
          (x,body) <- unbind binding
          reduce steps t2 (\steps' v -> do
                       val <- isValue v
                       if steps' == 0 || not val
                          then do
                            emit $ "Stuck term" $$$ EApp t1' v
                            k steps (EApp t1' v)
                          else do
                            let tm' = subst x v body
                            logReduce (EApp t1' v) tm'
                            reduce (steps - 1) tm' k)

        k' steps t1'@(ERec binding) = do
          typeError "When evaluating, the term being applied is a 'Rec'. This should not happen."
                    [(text "The term being applied", disp t1'),
                     (text "The application", disp tm)]
        k' steps v1 = do
          ev <- erasedSynValue v1
          if isCon v1 && ev
             then reduce steps t2 (\steps' v2 -> k steps (EApp v1 v2))
             else k steps (EApp v1 t2)

        isCon (ECon _) = True
        isCon (EApp l _) = isCon l
        isCon _ = False


        isValue t = do
          tp <- lookupTermProof t
          disableValueRestriction <- getOptDisableValueRestriction
          ev <- erasedSynValue t
          case tp of
            Nothing -> return (ev || disableValueRestriction)
            Just _ -> do
              emit $ "Found a termination proof for non-value" <++> t
              return True


reduce steps (ECase scrutinee alts) k = reduce steps scrutinee k'
  where k' 0 t = k 0 (ECase t alts)
        k' steps v = case findCon v [] of
                       (ECon c:args) -> do
                         branch <- substPat c args alts
                         logReduce (ECase v alts) branch
                         reduce (steps - 1) branch k
                       _ -> do
                         rw <- lookupRewrite scrutinee
                         case rw of
                           Just rhs -> do
                                   reduce steps rhs k'
                           Nothing -> do
                             k steps (ECase v alts)

        findCon :: EExpr -> [EExpr] -> [EExpr]
        findCon c@(ECon _) args = (c:args)
        findCon (EApp t a) args = findCon t (a:args)
        findCon _ _ = []
        substPat c args [] = err $ "Can't find constructor"
        substPat c args (alt:alts) = do
          ((c',vs),body) <- unbind alt
          if string2Name c' == c
             then return $ substs (zip vs args) body
             else substPat c args alts


reduce steps (ELet binding) k = do
  ((x,Embed t), body) <- unbind binding
  let k' steps t' = do
          ev <- erasedSynValue t'
          if ev
             then do let body' = subst x t' body
                     reduce (steps - 1) body' k
             else return $ ELet (bind (x,Embed t') body)
  reduce steps t k'


reduce steps t@(ERec binding) k = do
  ((f,args),body) <- unbind binding
  let t' = foldr (\n bdy -> ELambda (bind n bdy)) (subst f t body)  args
  k steps t'
reduce steps t@(ELambda _) k = k steps t
reduce steps EType k = k steps EType



reduce steps t k = die $ "reduce" <++> t

patMatch (c,args) [] = err "No Pattern Match"
patMatch t@(ECon c,args) (b:bs) = do
  ((cname,vars),body) <- unbind b
  if string2Name cname == c
     then return $ substs (zip vars args) body
     else patMatch t bs


-- getCons :: Expr -> Maybe (Expr,[Expr])
-- getCons t@(Con _) = return (t,[])
-- getCons t = case splitApp t of
--               (c@(Con _):cs) -> return (c,cs)
--               _ -> Nothing





