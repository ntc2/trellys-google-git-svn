{-# LANGUAGE TypeSynonymInstances, ExistentialQuantification, NamedFieldPuns, ParallelListComp, FlexibleContexts, ScopedTypeVariables #-}
-- | The Trellys core typechecker, using a bi-directional typechecking algorithm
-- to reduce annotations.
module Language.Trellys.TypeCheck
  (tcModule, tcModules, runTcMonad, emptyEnv)
where

import Language.Trellys.Syntax

import Language.Trellys.PrettyPrint(Disp(..))
import Language.Trellys.OpSem

import Language.Trellys.Options
import Language.Trellys.Environment
import Language.Trellys.Error
import Language.Trellys.TypeMonad

import Language.Trellys.GenericBind
import Generics.RepLib.Lib(subtrees)
import Text.PrettyPrint.HughesPJ

import Control.Monad.Reader hiding (join)
import Control.Monad.Error hiding (join)
import Control.Applicative

import Data.Maybe
import Data.List
import qualified Data.Set as S

-- import System.IO.Unsafe (unsafePerformIO)

natType :: Term
natType = Con (string2Name "Nat")

{-
  We rely on two mutually recursive judgements:

  * ta is an analysis judgement that takes a term and a type and checks it

  * ts is a synthesis that takes a term and synthesizes a type

  Both functions also return an annotated term which is a (possibly)
  elaborated version of the input term.

  In both functions, we assume that the context (gamma) is an implicit argument,
encapsulated in the TcMonad.

 -}


-- | kind check, for check = synthesis ?

-- Check that tm is a wellformed type at some level
kc :: Theta -> Term -> TcMonad ()
kc th tm = do
  (_,ty) <- ts th tm
  when (isNothing $ isType ty) $
    err [DD tm, DS "is not a well-formed type at", DD th]

-- | type analysis
ta :: Theta -> Term -> Term -> TcMonad Term
-- Position terms wrap up an error handler
ta th (Pos p t) ty = do
  ta th t ty `catchError`
         \(Err ps msg) -> throwError $ Err ((p,t):ps) msg
ta th tm (Pos _ ty) = ta th tm ty

ta th (Paren a) ty = liftM Paren $ ta th a ty
ta th tm (Paren ty) = ta th tm ty

-- rule T_join
ta th (Join s1 s2) (TyEq a b) =
  do kc th (TyEq a b)
     (_,k1) <- ts Program a
     (_,k2) <- ts Program b
     picky <- getFlag PickyEq
     when (picky && not (k1 `aeqSimple` k2)) $
         err [DS "Cannot join terms of different types:", DD a,
         DS "has type", DD k1, DS "and", DD b, DS "has type", DD k2]
     t1E <- erase =<< substDefs a
     t2E <- erase =<< substDefs b
     joinable <- join s1 s2 t1E t2E
     unless joinable $
       err [DS "The erasures of terms", DD a, DS "and", DD b,
            DS "are not joinable."]
     return (Join s1 s2)

-- rule T_contra
ta th (Contra a) b =
  do kc th b
     (ea, tyA) <- ts Logic a
     case isTyEq tyA of
       Just (cvs1, cvs2) ->
         case (splitApp cvs1, splitApp cvs2) of
           ((Con c1, vs1), (Con c2, vs2)) ->
              do when (c1 == c2) $
                   err [DS "The equality proof", DD tyA,
                        DS "isn't necessarily contradictory because the",
                        DS "constructors on both sides are the same."]
                 unless (   (all (isValue . fst) vs1)
                         && (all (isValue . fst) vs2)) $
                   err [DS "The equality proof", DD tyA,
                        DS "isn't necessarily contradictory because the",
                        DS "constructors are applied to non-values."]
                 return (Contra ea)
           _ -> err [DS "The equality proof supplied to contra must show",
                     DS "two different constructor forms are equal.",
                     DS "Here it shows", DD tyA]
       _ -> err [DS "The argument to contra must be an equality proof.",
                 DS "Here its type is", DD tyA]


-- rule T_abort
ta Logic Abort _ = err [DS "abort must be in P."]
ta Program Abort tyA = do kc Program tyA ; return Abort

-- Rules T_lam1 and T_lam2
ta th (Lam lep lbody) a@(Arrow ath aep abody) = do

  -- First check the arrow type for well-formedness
  kc th a

  -- pull apart the bindings and make sure the epsilons agree
  Just (x,body,(_,tyA),tyB) <- unbind2 lbody abody

  when (lep /= aep) $
       err ([DS "Lambda annotation", DD lep,
             DS "does not match arrow annotation", DD aep])

  -- typecheck the function body
  ebody <- extendCtx (Sig x ath (unembed tyA)) (ta th body tyB)

  -- perform the FV and value checks if in T_Lam2
  bodyE <- erase body
  -- The free variables function fv is ad-hoc polymorphic in its
  -- return type
  --
  --   fv :: (Rep b, Alpha a) => a -> Set (Name b)
  --
  -- and returns the free (Name b)'s in its argument.  Now, here
  --
  --   a :: ETerm
  --
  -- and
  --
  --   x :: Name Term
  --
  -- and we need to check if there are any free (Name ETerm)s with
  -- name x in a.  So, x needs to be converted into a (Name ETerm).
  -- The translate function can do this, but it's also ad-hoc
  -- polymorphic in its return type
  --
  --   translate :: (Rep b) => Name a -> Name b
  --
  -- so we fix the return type to avoid ambiguity:
  let xE = translate x :: EName
  -- Q: What happens if we instead do
  --
  --   x `S.member` fv bodyE
  --
  -- below? A: fv bodyE is always empty and the FV check always
  -- passes!
  when (lep == Erased && xE `S.member` fv bodyE) $
       err [DS "ta: In implicit lambda, variable", DD x,
            DS "appears free in body", DD body]

  when (th == Program && lep == Erased) $ do
    gen <- checkQ body
    unless gen $
        err [DS "ta : The body of an implicit lambda must be a quantifiable term",
             DS "but here is:", DD body]

  return (Lam lep (bind x ebody))



-- rules T_rnexp and T_rnimp
ta _ (NatRec ep binding) arr@(Arrow ath aep abnd) = do
  kc Logic arr

  unless (ath == Logic) $
    err [DS "ta: recnat defines a function which takes a logical argument,",
         DS "here a computational argument was specified"]

  unless (ep == aep) $
     err [DS "ta : expecting argument of recnat to be", DD aep,
          DS "got", DD ep]

  ((dumbvar,nat),dumbbody) <- unbind abnd
  unless (unembed nat `aeqSimple` natType) $
     err [DS "ta: expecting argument of recnat to be Nat got ", DD (unembed nat)]

  ((f,y),a) <- unbind binding
  -- to get the body "tyB" as it appears on paper, we must replace the
  -- extra variable we got from opening the binding
  let tyB = subst dumbvar (Var y) dumbbody

  -- next we must construct the type A.  we need new variables for x and z
  x <- fresh (string2Name "x")
  z <- fresh (string2Name "z")
  let xTyB = subst y (Var x) tyB
      eqType = TyEq (Var y)
                    (App Runtime (Con $ string2Name "Succ") (Var x))

      tyA = Arrow Logic ep (bind (x,embed natType)
                  (Arrow Logic Erased (bind (z,embed eqType)
                         xTyB)))
  -- Finally we can typecheck the fuction body in an extended environment
  ea <- extendCtx (Sig f Logic tyA) $
          extendCtx (Sig y Logic natType) $ ta Logic a tyB
  -- in the case where ep is Erased, we have the two extra checks:
  aE <- erase a
  when (ep == Erased && translate y `S.member` fv aE) $
       err [DS "ta: In implicit recnat, variable", DD y,
            DS "appears free in body", DD a]

  when (ep == Erased) $ do
       chk <- checkQ a
       unless chk $
              err [DS "ta : The body of an implicit natrec must be quantifiable",
                   DS "but here is:", DD a]
  return (NatRec ep (bind (f,y) ea))


-- rules T_rexp and T_rimp
ta Logic (Rec _ _) _ =
  err [DS "rec must be P."]

ta Program (Rec ep binding) fty@(Arrow ath aep abnd) = do
  kc Program fty
  unless (ep == aep) $
         err [DS "ta : expecting argument of rec to be",
              DD aep, DS ", got", DD ep]

  ((dumby,tyA),dumbbody) <- unbind abnd
  ((f,y),a) <- unbind binding
  let tyB = subst dumby (Var y) dumbbody

  ea <- extendCtx (Sig f Program fty) $
          extendCtx (Sig y ath (unembed tyA)) $
            ta Program a tyB

  -- perform the FV and value checks if in T_RecImp
  aE <- erase a
  when (ep == Erased && translate y `S.member` fv aE) $
       err [DS "ta: In implicit rec, variable", DD y,
            DS "appears free in body", DD a]
  when (ep == Erased) $ do
    chk <- checkQ a
    unless chk $
       err [DS "ta : The body of an implicit rec must be quantifiable",
            DS "but here is:", DD a]
  return (Rec ep (bind (f,y) ea))

-- rule T_case
ta th (Case b bnd) tyA = do
  -- premises 1, 3 and 4: we check that the scrutinee is the element of some
  -- datatype defined in the context
  -- SCW: can relax and check this at P even with th is v if b is "valuable"
  (eb,bty) <- ts th b
  (d,bbar,delta,cons) <-
    case splitApp bty of
      (Con d, apps) -> do
         ent <- lookupCon d
         case ent of
           (Left (delta,th',_,Just cons)) ->
             do unless (th' <= th) $
                   err [DS "Attempted to pattern match on an element of the",
                        DS "datatype", DD d, DS "in the Logical fragment, but",
                        DS "it is programmatic."]
                unless (length apps == length delta) $
                   err [DS "Attempted to match against", DD b,
                        DS "with type", DD bty, DS "where", DD d,
                        DS "is applied to the wrong number of arguments."]
                return (d,map (\(a,_) -> (a,Erased)) apps, delta, cons)
           (Left (_,_,_,Nothing)) ->
              err [DS "Scrutinee ", DD b,
                   DS "is a member of an abstract datatype - you may not",
                   DS "pattern match on it."]
           _ ->
              err [DS "Scrutinee ", DD b,
                   DS "must be a member of a datatype, but is not"]
      _ -> err [DS "Scrutinee ", DD b,
                DS "must be a member of a datatype, but is not"]

  -- premise 2: the return type must be well kinded
  kc th tyA

  -- premises 4 and 5: we define a function to map over the
  -- branches that checks each is OK (and elaborates it)
  (y,mtchs) <- unbind bnd
  unless (   (length mtchs == length cons)
          && (length (nub $ map fst cons) == length cons)) $
     err [DS "Wrong number of pattern match branches for datatype", DD d]
  let
    checkBranch :: Match -> TcMonad Match
    checkBranch (c, cbnd) =
      case lookup c cons of
        Nothing -> err [DD c, DS "is not a constructor of type", DD d]
        Just ctyp ->
          do (deltai',ai) <- unbind cbnd
             (dumbdeltai,_) <- splitPi ctyp
             unless (length deltai' == length dumbdeltai) $
                err [DS "wrong number of argument variables for constructor",
                     DD c, DS "in pattern match."]
             unless (   (map snd deltai')
                     == map (\(_,_,_,e) -> e) dumbdeltai) $
                err [DS "wrong epsilons on argument variables for constructor",
                     DD c, DS "in pattern match."]
             let deltai = swapTeleVars dumbdeltai (map fst deltai')
                 subdeltai = substs (zip (teleVars delta) (map fst bbar)) deltai
                 eqtype = TyEq b (teleApp (multiApp (Con c) bbar) deltai)
             -- premise 5
             eai <- extendCtx (Sig y Logic eqtype) $
                      extendCtxTele subdeltai $ ta th ai tyA
             -- premise 6
             aE <- erase ai
             let yEs = map translate $ y : domTeleMinus deltai
             let shouldBeNull = S.fromList yEs `S.intersection` fv aE
             unless (S.null shouldBeNull) $
               err [DS "The constructor argument(s) and/or scrutinee equality proof",
                    DD . S.toList $ shouldBeNull,
                    DS "should not appear in the erasure", DD aE,
                    DS "of the term", DD ai,
                    DS "because they bind compiletime variables."]
             return (c, bind deltai' eai)
  emtchs <- mapM checkBranch mtchs
  return (Case eb (bind y emtchs))

-- implements the checking version of T_let1 and T_let2
ta th (Let th' ep bnd) tyB =
 do -- begin by checking syntactic -/L requirement and unpacking binding
    when (ep == Erased && th' == Program) $
       err [DS "Implicit lets must bind logical terms."]
    ((x,y,a),b) <- unbind bnd
    -- premise 1
    (ea,tyA) <- ts th' (unembed a)
    -- premise 2
    eb <- extendCtx (Sig y Logic (TyEq (Var x) (unembed a))) $
            extendCtx (Sig x th' tyA) $
              ta th b tyB
    -- premise 3
    kc th tyB
    -- premises 4 and 5
    bE <- erase b
    when (translate y `S.member` fv bE) $
      err [DS "The equality variable bound in a let is not allowed to",
           DS "appear in the erasure of the body, but here", DD y,
           DS "appears in the erasure of", DD b]
    when (ep == Erased && translate x `S.member` fv bE) $
      err [DS "The variables bound in an implicit let are not allowed to",
           DS "appear in the erasure of the body, but here", DD x,
           DS "appears in the erasure of", DD b]
    unless (th' <= th) $
      err [DS "Program variables can't be bound with let expressions in",
           DS "Logical contexts because they would be normalized when the",
           DS "expression is."]
    return (Let th' ep (bind (x,y,embed ea) eb))
-- rule T_At
ta _ (At ty th') (Type i) = do 
   ea <- ta th' ty (Type i) 
   return (At ea th')
-- rule T_AtP
ta Program a (At tyA th) = ta th a tyA
-- rule T_AtLL
ta Logic a (At tyA Logic) = ta Logic a tyA
-- rule T_AtLP
ta Logic a (At tyA Program) = 
   -- allow a to be "provable value here..."
   if (isValue a) then 
      ta Program a tyA
   else 
      -- one last chance, check if it is a log term immediately 
      -- coerced to be programmatic
      ta Logic a tyA    
   
ta th (TerminationCase s binding) ty = do 
    (es, sty) <- ts Program s
    (w,(abort,tbind)) <- unbind binding
    (v, terminates) <- unbind tbind
    eabort <- extendCtx (Sig w Logic (TyEq (Ann Abort sty) s))
                 $ ta th abort ty
    eterm  <- extendCtx (Sig v Program sty)
                 $ extendCtx (Sig w Logic (TyEq (Var v) s))
                 $ ta th terminates ty
    return (TerminationCase es (bind w (eabort, (bind v eterm))))

-- rule T_chk
ta th a tyB = do
  (ea,tyA) <- ts th a
  subtype th tyA tyB
    `catchError`
       \e -> err $ [DS "When checking term", DD a, DS "against type",
                    DD tyB, DS "the distinct type", DD tyA,
                    DS "was inferred, and it isn't a subtype:\n", DD e]
  return ea

------------------------------
------------------------------
-------- Synthesis
------------------------------
------------------------------

-- | type synthesis
-- Returns (elaborated term, type of term)
ts :: Theta -> Term -> TcMonad (Term,Term)
ts tsTh tsTm =
  do (etsTm, typ) <- ts' tsTh tsTm
     return $ (etsTm, delPosParen typ)
  where
    ts' :: Theta -> Term -> TcMonad (Term,Term)
    ts' th (Pos p t) =
      ts' th t `catchError`
         \(Err ps msg) -> throwError $ Err ((p,t):ps) msg

    ts' th (Paren a) =
      do (ea,ty) <- ts' th a
         return (Paren ea, ty)

    -- Rule T_var
    ts' th (Var y) =
      do x <- lookupTy y
         case x of
           Just (th',ty) -> do
             isFO <- isFirstOrder ty
             unless (th' <= th || isFO) $
               err [DS "Variable", DD y, DS "is programmatic, but it was checked",
                    DS "logically (and ", DD ty, DS " is not a FO type." ]
             return (Var y, ty)
           Nothing -> err [DS "The variable", DD y, DS "was not found."]

    -- Rule T_type
    ts' _ (Type l) = return (Type l,  Type (l + 1))

    -- Rules T_pi and T_pi_impred
    ts' th (Arrow th' ep body) =
      do ((x,tyA), tyB) <- unbind body
         (etyA, tytyA) <- ts th' (unembed tyA)
         (etyB, tytyB) <- extendCtx (Sig x th' (unembed tyA)) $ ts th tyB
         case (isType tytyA, isType tytyB) of
           (Just _, Just 0) -> return $ (Arrow th' ep  (bind (x,embed etyA) etyB), Type 0)
           (Just n, Just m) -> return $ (Arrow th' ep  (bind (x,embed etyA) etyB), Type (max n m))
           (Just _, _)      -> err [DD tyB, DS "is not a type."]
           (_,_)            -> err [DD (unembed tyA), DS "is not a type."]

    -- Rules T_tcon, T_acon and T_dcon
    ts' th (Con c) =
      do typC <- lookupCon c
         case typC of
           (Left (delta, th', lev, _)) ->
             do unless (th' <= th) $
                  err [DS "Constructor", DD c,
                       DS "is programmatic, but it was checked logically."]
                return (Con c, telePi (map (\(t,a,b,_) -> (t,a,b,Runtime)) delta)
                                      (Type lev))
           (Right (delta, th', tm)) ->
             do unless (th' <= th) $
                  err [DS "Constructor", DD c,
                       DS "is programmatic, but it was checked logically."]
                return $ (Con c, telePi (map (\(t,a,b,_) -> (t,a,b,Erased)) delta) tm)

    -- rule T_app
    ts' th tm@(App ep a b) =
      do (ea,tyArr) <- ts th a
         case isArrow tyArr of
           Nothing -> err [DS "ts: expected arrow type, for term ", DD a,
                           DS ". Instead, got", DD tyArr]
           Just (th', epArr, bnd) -> do
             ((x,tyA),tyB) <- unbind bnd
             unless (ep == epArr) $
               err [DS "Application annotation", DD ep, DS "in", DD tm,
                    DS "doesn't match arrow annotation", DD epArr]

             let b_for_x_in_B = subst x b tyB
             -- check that the result kind is well-formed
             kc th b_for_x_in_B
             -- check the argument, at the "A @ th'" type
             -- if the arg is implicit, make sure that it is total
             let thb = if ep == Erased then Logic else th
             eb <- ta thb b (At (unembed tyA) th')

{-
             -- To implement app1 and app2 rules, we first try to
             -- check the argument Logically and check the resulting
             -- substitution.  If either fails, we would have to use
             -- App2.  In that case, th' must be Program and the argument
             -- must be a value.

             let b_for_x_in_B = subst x b tyB

             eb <- ((kc th b_for_x_in_B >> ta Logic b (unembed tyA))
                    `catchError`
                      \e ->
                        if th' == Logic then throwError e else
                          do tot <- isTotal Program b
                             unless (tot || th==Program) $
                                    err [DS "When applying to an argument with classifier P in a logical context,",
                                         DS "the term must be classified Total, but",
                                         DD b, DS "is not.",
                                         DS "This is the dreaded value restriction:",
                                         DS "use a let-binding to make the term a value."]

                             ta Program b (unembed tyA)) -}
             return (App ep ea eb, b_for_x_in_B)


    -- rule T_eq
    ts' _ (TyEq a b) = do
      (ea,_) <- ts' Program a
      (eb,_) <- ts' Program b
      return $ (TyEq ea eb, Type 0)

    -- rule T_conv
    ts' th (Conv b as bnd) =
      do (xs,c) <- unbind bnd

         erasedTerm <- erase c
         let runtimeVars = fv erasedTerm

         let chkTy (False,pf) _ = do
               (e,t) <- ts Logic pf
               return ((False,e),t)
             chkTy (True,pf) var = do
               (e,_) <- ts Logic pf
               -- TODO: Check to see if result is a Type 0?
               when (translate var `S.member` runtimeVars) $
                   err [DS "Equality proof", DD pf, DS "is marked erased",
                        DS "but the corresponding variable", DD var,
                        DS "appears free in the erased term", DD erasedTerm]
               return ((True,e),pf)

         (eas,atys) <- liftM unzip $ zipWithM chkTy as xs

         picky <- getFlag PickyEq
         let errMsg aty =
               err $ [DS "The second arguments to conv must be equality proofs,",
                      DS "but here has type", DD aty]
--         let isTyEq' aTy = maybe (errMsg aTy) return (isTyEq aTy)
--         (tyA1s,tyA2s) <- liftM unzip $ mapM isTyEq' atys


         (tyA1s,tyA2s, ks) <- liftM unzip3 $ mapM (\ aty -> do
              case isTyEq aty of
                Just (tyA1, tyA2) -> do
                 (_,k1) <- ts Program tyA1
                 (_,k2) <- ts Program tyA2
                 when (picky && (not (k1 `aeqSimple` k2))) $ err
                   [DS "Terms ", DD tyA1, DS "and", DD tyA2,
                    DS " must have the same type when used in conversion.",
                    DS "Here they have types: ", DD k1, DS "and", DD k2,
                    DS "respectively."]

                 return (tyA1, tyA2, k1)
                _ -> errMsg aty) atys

         let cA1 = substs (zip xs tyA1s) c
         let cA2 = substs (zip xs tyA2s) c
         eb <- ta th b cA1
         if picky then
            -- check c with extended environment
            -- Don't know whether these should be logical or programmatic
            let decls = zipWith (\ x t -> Sig x Logic t) xs ks in
              extendCtxs decls $ kc th c
           else
            -- check c after substitution
            kc th cA2
         return (Conv eb eas (bind xs c), cA2)

    -- rule T_annot
    ts' th (Ann a tyA) =
      do ea <- ta th a tyA
         return (Ann ea tyA, tyA)

    -- the synthesis version of rules T_let1 and T_let2
    ts' th (Let th' ep bnd) =
     do -- begin by checking syntactic -/L requirement and unpacking binding
        when (ep == Erased && th' == Program) $
          err [DS "Implicit lets must bind logical terms."]
        ((x,y,a),b) <- unbind bnd
        -- premise 1
        (ea,tyA) <- ts th' (unembed a)
        -- premise 2
        (eb,tyB) <- extendCtx (Sig y Logic (TyEq (Var x) (unembed a))) $
                      extendCtx (Sig x th' tyA) $
                        ts th b
        -- premise 3
        kc th tyB
        -- premises 4 and 5
        bE <- erase b
        when (translate y `S.member` fv bE) $
          err [DS "The equality variable bound in a let is not allowed to",
               DS "appear in the erasure of the body, but here", DD y,
               DS "appears in the erasure of", DD b]
        when (ep == Erased && translate x `S.member` fv bE) $
          err [DS "The variables bound in an implicit let are not allowed to",
               DS "appear in the erasure of the body, but here", DD x,
               DS "appears in the erasure of", DD b]
        unless (th' <= th) $
          err [DS "Program variables can't be bound with let expressions in",
               DS "Logical contexts because they would be normalized when the",
               DS "expression is."]
        return (Let th' ep (bind (x,y,embed ea) eb), tyB)

    -- halt e' by t at x . body : ExistsP1L0 T' (\x . x = e')
    ts' th (Halt e' t bnd) = do
      -- Check e' as a Program: we don't need to prove termination for Logic terms
      (ee', e'ty) <- ts Program e'
      (et, tty) <- ts Logic t

      -- Does t have type ExistsP1L0 T (\x.b) for some T and b?
      let dtty = delPosParenDeep tty
          (App Runtime (App Runtime (Con exists') (Con ety)) (Lam Runtime eqBnd)) = dtty
      unless (exists' `aeq` string2Name "ExistsP1L0") $
        err [DS "Wrong type (expecting ExistsP1L0): ", DD exists']

      -- Does t prove that e terminates, for some e?
      (y,TyEq (Var y') e) <- unbind eqBnd
      unless (y `aeq` y') $
        err [DS "Wrong variable in equality:", DD y, DS "/=", DD y']

      -- Does e = body[e'/x] ?
      -- ??? Should we elaborate body to ebody instead (we use ee' below)?
      (x,body) <- unbind bnd
      -- ??? Why use ee' instead of e'?
      unless (e `aeqSimple` subst x ee' body) $
        err [DS "Substitution not equal:", DD e, DS "/=", DD $ subst x ee' body]

      -- Does x occur strictly in body ?
      strict <- strictBinding bnd
      unless strict $
        err [DS "Binding of", DD x, DS "is not strict in", DD body]

      -- Build AST for return type: ExistsP1L0 T' (\x . x = e')
      x' <- fresh $ string2Name "x"
      let ty =  (App Runtime (App Runtime (Con (string2Name "ExistsP1L0")) (e'ty))
                             (Lam Runtime (bind x' (TyEq (Var x') e'))))

      -- ??? Could we return an ExistsP1L0 *instance* here to make case
      -- matching on Halt trivial?
      return (Halt ee' et (bind x body), ty)
     where
      strictBinding :: Bind (Name Term) Term -> TcMonad Bool
      strictBinding bnd = do
        (x,e) <- unbind bnd
        e'    <- erase e
        translate x `isStrictIn` e'

      isStrictIn :: EName -> ETerm -> TcMonad Bool
      x `isStrictIn` e = i e where
        -- 'i body' checks that 'x' is strict in 'body'
        i (EVar y)     = return $ x == y
        i (EApp f e)   = (||) <$> i f <*> i e
        i (ECase e _)  = i e -- could be more complete by checking that x is evaluated in all branches ...
        i (ETerminationCase e _) = i e
        i (ELet e bnd) = do (_,body) <- unbind bnd
                            (||) <$> i e <*> i body
        i _            = return False

    ts' _ (At tyA th') = do 
      (ea, s) <- ts' th' tyA
      return (At ea th', s)

    ts' _ tm = err $ [DS "Sorry, I can't infer a type for:", DD tm,
                      DS "Please add an annotation.",
                      DS "NB: This error happens when you misspell,",
                      DS "so check your spelling if you think you did annotate."]


--------------------------------------------------------
-- Using the typechecker for decls and modules and stuff
--------------------------------------------------------


-- | Typecheck a collection of modules. Assumes that each modules
-- appears after its dependencies. Returns the same list of modules
-- with each definition typechecked and elaborated into the core
-- language.
tcModules :: [Module] -> TcMonad [Module]
tcModules mods = foldM tcM [] mods
  -- Check module m against modules in defs, then add m to the list.
  where defs `tcM` m = do -- "M" is for "Module" not "monad"
          let name = moduleName m
          liftIO $ putStrLn $ "Checking module " ++ show name
          m' <- defs `tcModule` m
          return $ defs++[m']

-- | Typecheck an entire module.
tcModule :: [Module] -- ^ List of already checked modules (including their Decls).
         -> Module           -- ^ Module to check.
         -> TcMonad Module   -- ^ The same module with all Decls checked and elaborated.
tcModule defs m' = do checkedEntries <- extendCtxMods importedModules $
                                          foldr tcE (return [])
                                                  (moduleEntries m')
                      return m'{ moduleEntries = checkedEntries }
  where d `tcE` m = do
          -- Extend the Env per the current Decl before checking
          -- subsequent Decls.
          x <- tcEntry d
          case x of
            AddHint  hint  -> extendHints hint m
                           -- Add decls to the Decls to be returned
            AddCtx decls -> liftM (decls++) (extendCtxs decls m)
        -- Get all of the defs from imported modules (this is the env to check current module in)
        importedModules = filter (\aMod -> (ModuleImport (moduleName aMod)) `elem` moduleImports m') defs
        -- importedModules =
        --   [mod |
        --    mod <- defs,
        --           (ModuleImport (moduleName mod)) `elem` moduleImports m']

-- | The Env-delta returned when type-checking a top-level Decl.
data HintOrCtx = AddHint Decl
               | AddCtx [Decl]
                 -- Q: why [Decl] and not Decl ? A: when checking a
                 -- Def w/o a Sig, a Sig is synthesized and both the
                 -- Def and the Sig are returned.

tcEntry :: Decl -> TcMonad HintOrCtx

tcEntry (Def n term) = do
  oldDef <- lookupDef n
  case oldDef of
    Nothing -> tc
    Just term' -> die term'
  where
    tc = do
      lkup <- lookupHint n
      case lkup of
        Nothing -> do (eterm,ty) <- ts Logic term
                      -- Put the elaborated version of term into the context.
                      return $ AddCtx [Sig n Logic ty, Def n eterm]
        Just (theta,ty) ->
          let handler (Err ps msg) = throwError $ Err (ps) (msg $$ msg')
              msg' = disp [DS "When checking the term ", DD term,
                           DS "against the signature", DD ty]
          in do
            eterm <- ta theta term ty `catchError` handler
            -- If we already have a type in the environment, due to a sig
            -- declaration, then we don't add a new signature.
            --
            -- Put the elaborated version of term into the context.
            return $ AddCtx [Sig n theta ty, Def n eterm]
    die term' =
      let (Pos p t) = term
          (Pos p' _) = term'
          msg = disp [DS "Multiple definitions of", DD n,
                      DS "Previous definition at", DD p']
      in do throwError $ Err [(p,t)] msg

-- rule Decl_data
tcEntry dt@(Data t delta th lev cs) =
  do ---- Premise 1
     kc th (telePi delta (Type lev))

     ---- Premise 2 in two parts.
     ---- Part 1: make sure the return type of each constructor is right
     let
       checkConRet :: TName -> Term -> TcMonad ()
       checkConRet c tm =
         do (_,ret) <- splitPi tm
            let (t',tms) = splitApp ret
                correctApps = map (\(v,_,_,_) -> (Var v,Runtime)) delta
            unless (    (Con t `aeqSimple` t')
                     && (tms `aeqSimple` correctApps)) $
              err [DS "Constructor", DD c,
                   DS "must have return type",
                   DD (multiApp (Con t) correctApps)]

     mapM_ (uncurry checkConRet) cs

     -- Part 2: type check the whole constructor type
     extendCtx (AbsData t delta th lev) $
       mapM_ (\(_,tyAi) -> ta th (telePi delta tyAi) (Type lev)) cs

     -- Premise 3: check that types are strictly positive.
     mapM_ (positivityCheck t) cs

     ---- finally, add the datatype to the env and perform action m
     return $ AddCtx [dt]

tcEntry dt@(AbsData _ delta th lev) =
  do kc th (telePi delta (Type lev))
     return $ AddCtx [dt]

tcEntry s@(Sig n th ty) = do
  duplicateTypeBindingCheck n ty
  kc th ty
  return $ AddHint s

tcEntry s@(Axiom n th ty) = do
  duplicateTypeBindingCheck n ty
  kc th ty
  return $ AddCtx [s]

duplicateTypeBindingCheck :: TName -> Term -> TcMonad ()
duplicateTypeBindingCheck n ty = do
  -- Look for existing type bindings ...
  l  <- lookupTy n
  l' <- lookupHint n
  -- ... we don't care which, if either are Just.
  case catMaybes [l,l'] of
    [] ->  return ()
    -- We already have a type in the environment so fail.
    (_,ty'):_ ->
      let (Pos p  _) = ty
          (Pos p' _) = ty'
          msg = disp [DS "Duplicate type signature ", DD ty,
                      DS "for name ", DD n,
                      DS "Previous typing at", DD p',
                      DS "was", DD ty']
       in
         throwError $ Err [(p,ty)] msg

-----------------------
------ subtyping
-----------------------
subtype :: Theta -> Term -> Term -> TcMonad ()
subtype Program (Type _) (Type _) = return ()
subtype Logic (Type l1) (Type l2) =
  unless (l1 <= l2) $
    err [DS "In the logical fragment,", DD (Type l1),
         DS "is not a subtype of", DD (Type l2)]
subtype _ a b =
  unless (a' `aeqSimple` b') $
    err [DD a, DS "is not a subtype of", DD b]
  where a' = delPosParenDeep a
        b' = delPosParenDeep b

isFirstOrder :: Term -> TcMonad Bool
isFirstOrder (TyEq _ _) = return True
isFirstOrder (Pos _ ty) = isFirstOrder ty
isFirstOrder (Paren ty) = isFirstOrder ty
isFirstOrder ty = case splitApp ty of
      (Con d, apps) -> do
         ent <- lookupCon d
         return $ case ent of 
                    (Left _)  -> True  -- Datatype constructors are considered FO.
                    (Right _) -> False -- Data  constructors are not
      _ -> return False 
-- isFirstOrder ty = return $ ty `aeqSimple` natType

--debug n v = when False (liftIO (putStr n) >> liftIO (print v))
--debugNoReally n v = when True (liftIO (putStr n) >> liftIO (print v))


-- Positivity Check

-- | Determine if a data type only occurs in strictly positive positions in a
-- constructor's arguments.

positivityCheck
  :: (Fresh m, Disp d, MonadError Err m) =>
     Name Term -> (d, Term) -> m ()
positivityCheck tName (cName,ty)  = do
  (tele,_) <- splitPi ty
  _ <- mapM checkBinding tele
  return ()
 `catchError` \(Err ps msg) ->  throwError $ Err ps (msg $$ msg')
  where checkBinding (_,teleTy,Logic,_) = occursPositive tName teleTy
        checkBinding _ = return True
        msg' = text "When checking the constructor" <+> disp cName

occursPositive
  :: (Fresh m, MonadError Err m) => Name Term -> Term -> m Bool
occursPositive tName (Pos p ty) = do
  occursPositive tName ty `catchError`
         \(Err ps msg) -> throwError $ Err ((p,ty):ps) msg

occursPositive tName (Paren ty) = occursPositive tName ty
occursPositive tName aty@(Arrow _ _  _) = do
  (tele,_) <- splitPi aty
  let tys = [ty | (_,ty,_,_) <- tele]
      vars = S.unions $ map fv tys
      ok = not $ tName `S.member` vars
  unless ok $ err [DD tName, DS "occurs in non-positive position"]
  return True

occursPositive tName ty = do
  let children = subtrees ty
  res <- mapM (occursPositive tName) children
  return $ and res



-- Value restriction relaxation -- 'Q' and 'Total' Judgements

-- 'Q m' Judgement
-- Q_LAM


checkQ :: (MonadError Err m, Fresh m) => Term -> m Bool
checkQ (Pos p t) =
  checkQ t `catchError`
         \(Err ps msg) -> throwError $ Err ((p,t):ps) msg
checkQ (Paren t) = checkQ t

checkQ (Lam _ _) = return True
-- Q_REC
checkQ (Rec Runtime _) = return True

-- Q_RECM
checkQ (Rec Erased binding) = do
  ((_,_),body) <- unbind binding
  checkQ body

-- Q_CONS
--   base case: zero arguments
checkQ (Con _) = return True
--   step case: 1 or more arguments
checkQ t@(App _ (Con _) _) = do
  qs <- mapM (\(arg,_) -> checkQ arg) args
  return $ and qs
  where (_,args) = splitApp t

checkQ _ = return False



-- The 'TOTAL' judgement. In the draft core design, the 'total' does a check
-- that the term that is to be check is well typed. It turns out that this has
-- already been checked in those positions above where isTotal is called, so
-- that check has been commented out for efficency. This is not a particularly
-- safe decision.

isTotal
  :: Theta
     -> Term -- Term to check
     -> FreshMT (ReaderT Env (ErrorT Err IO)) Bool
isTotal Logic _ = return True
isTotal Program tm
  | isValue tm = return True -- TOT_VAL
  | otherwise =
    case tm of
      (Arrow _ _ binding) -> do
              ((_,tyA), tyB) <- unbind binding
              kc Program tm
              kc Program (unembed tyA)
              kc Program tyB
              totA <- isTotal Program (unembed tyA)
              totB <- isTotal Program tyB
              return (totA && totB)
      t@(App _ _ _) ->
        let (f,args) = splitApp t
        in case f of
             Con _ -> do
                    atots <- mapM (isTotal Program . fst) args
                    return $ and atots
             _ -> return False

      _ -> return False


-- Alpha equality, dropping parens and source positions.
aeqSimple :: Alpha t => t -> t -> Bool
aeqSimple x y = d x `aeq` d y where
  d = delAnnPosParenDeep -- was delPosParenDeep
