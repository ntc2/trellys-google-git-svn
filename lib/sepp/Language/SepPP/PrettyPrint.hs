{-# LANGUAGE StandaloneDeriving, DeriveDataTypeable, TypeSynonymInstances, FlexibleInstances, UndecidableInstances, PackageImports #-}
module Language.SepPP.PrettyPrint where

import Language.SepPP.Syntax

import Unbound.LocallyNameless hiding (empty,Val,Con)

import Text.PrettyPrint
import Control.Applicative hiding (empty)
import "mtl" Control.Monad.Reader
import Text.Parsec.Pos
import Text.Parsec.Error(ParseError,showErrorMessages,errorPos,errorMessages)
import qualified Data.Set as S


import Debug.Trace

class Disp d where
  disp :: d -> Doc


instance Disp Doc where
  disp = id
instance Disp String where
  disp  = text
instance Disp Expr where
  disp  = cleverDisp
instance Disp EExpr where
  disp = cleverDisp
instance Rep a => Disp (Name a) where
  disp = cleverDisp
instance Disp Module where
  disp = cleverDisp
instance Disp Int where
  disp = integer . toInteger

instance Disp Tele where
  disp = cleverDisp



instance Disp (Maybe Expr) where
  disp = maybe empty disp


-- Adapted from an adaptation from AuxFuns.
data DispInfo = DI {
    dispAvoid :: S.Set AnyName
  }

initDI :: DispInfo
initDI = DI S.empty

-- We still wrap this in a Fresh monad, so that we can print all of the
-- variables with their indicies, for debugging purposes.
type M = FreshMT (Reader DispInfo)

barenames = True
instance LFresh M where
  lfresh nm = do
    if barenames
       then fresh nm
        else do
          let s = name2String nm
          di <- ask
          return $ head (filter (\x -> AnyName x `S.notMember` (dispAvoid di))
                         (map (makeName s) [0..]))

  avoid names = local upd where
     upd di = di { dispAvoid = (S.fromList names) `S.union` (dispAvoid di) }



cleverDisp :: (Display d, Alpha d) => d -> Doc
cleverDisp d =
  runReader (runFreshMT dm) initDI where
    dm = let vars = S.elems (fvAny d)  in
         lfreshen vars $ \vars'  p ->
           (display (swaps p d))

-- 1. Display is monadic :: a -> M Doc
-- 2. Disp is pure :: a -> Doc

-- display :: Disp a => a -> IO Doc
-- display d = runFreshMT $ runReaderT (disp d) 0


class (Alpha t) => Display t where
  display :: t -> M Doc
  precedence :: t -> Int
  precedence _ = 0

instance Display String where
  display = return . text
instance Display Int where
  display = return . text . show
instance Display Integer where
  display = return . text . show
instance Display Double where
  display = return . text . show
instance Display Float where
  display = return . text . show
instance Display Char where
  display = return . text . show
instance Display Bool where
  display = return . text . show


-- class Disp a where
--   disp :: (Functor m, Fresh m) => a -> m Doc
--   precedence :: a -> Int
--   precedence x = 0

dParen:: (Display a) => Int -> a -> M Doc
dParen level x =
   if level >= (precedence x)
      then do { d <- display x; return(parens d)}
      else display x

termParen:: (Display a) => Int -> a -> M Doc
termParen level x =
   if level <= (precedence x)
      then do { d <- display x; return(parens d)}
      else display x

-- Set the precedence to i. If this is < than the current precedence, then wrap
-- this with parens.
-- withPrec:: Int -> m
withPrec i m = do
  dm <- local (const i) m
  cur <- ask
  if i < cur
     then return $ parens dm
     else return $ dm

instance Rep a => Display (Name a) where
  display = return . text . name2String

instance Display Expr where
  display (Var n) = return $ text $ name2String n
  display (Con n) = return $ text $ name2String n
  display (Formula 0) = return $ text "Form"
  display (Formula n) = return $ text "Form" <+> integer n
  display Type = return $ text "Type"

  display (Pi stage binding) = do
      lunbind binding fmt
    where fmt ((n,ty),ran) = do
                        dn <- display n
                        dty <- display ty
                        dran <- display ran
                        return $ bindingWrap stage (dn <+> colon <+> dty) <+> text "->" <+> dran
          wrap Dynamic = parens
          wrap Static =  brackets


  display (Forall binding) = do
    lunbind binding $ \((n,ty),ran) -> do
    dn <- display n
    dty <- display ty
    dran <- display ran
    return $ text "forall" <+> parens (dn <+> colon <+> dty) <+> text "." <+> dran

  display (t@(App t0 stage t1)) = do
    d0 <- dParen (precedence t - 1) t0
    d1 <- dParen (precedence t) t1
    return $ d0 <+> ann stage d1
   where ann Static = brackets
         ann Dynamic = id


  display (Lambda kind stage binding) = do
    lunbind binding $ \((n,ty),body) -> do
    dty <- display ty
    dn <- display n
    dbody <- display body
    return $ text "\\" <+> bindingWrap stage (dn <+> colon <+> dty) <+>
             absOp kind <+> dbody

    where absOp Form = text "=>"
          absOp Program = text "->"

  display (Case scrutinee termWitness binding) = do
   lunbind binding $ \(consEq,alts) -> do
    dScrutinee <- display scrutinee
    dConsEq <- braces <$> display consEq
    dTermWitness <- maybe (return empty) display termWitness
    dAlts <- mapM dAlt alts
    return $ text "case" <+> dScrutinee <+> dConsEq <+> dTermWitness <+> text "of" $$
             nest 2 (vcat dAlts)

    where dAlt alt = do
            lunbind alt $ \((con,pvars),body) -> do
            dPvars <- mapM display pvars
            dBody <- display body
            return $ cat [text con <+> hsep dPvars <+> text "-> ",
                          nest 2 dBody]


  display (TerminationCase scrutinee binding) =
    lunbind binding $ \(n,(diverge,terminate)) -> do
                        dScrutinee <- display scrutinee
                        dDiverge <- display diverge
                        dTerminate <- display terminate
                        dn <- display n
                        return $ hang (text "termcase" <+> dScrutinee <+> braces dn <+> text "of") 2
                                 (braces (text "abort" <+> text "->" <+> dDiverge <> semi $$
                                          text "!" <+> text "->" <+> dTerminate))


  display (Join i0 i1) =
    return $ text "join" <+> integer i0 <+> integer i1


  display (t@(Equal t0 t1)) = do
                     d0 <- dParen (precedence t) t0
                     d1 <- dParen (precedence t) t1
                     return $ fsep [d0, text "=", d1]

  display (w@(Val t)) = do
    d <- termParen (precedence w) t
    return $ text "value" <+> d

  display (w@(Terminates t)) = do
                     dt <- termParen (precedence w) t
                     return $ dt <+> text "!"


  display (t@(Contra t0)) = do
    d0 <- termParen (precedence t) t0
    return $ text "contra" <+> d0

  display (t@(ContraAbort t0 t1)) = do
    d0 <- termParen (precedence t) t0
    d1 <- termParen (precedence t) t1
    return $ text "contraabort" <+> d0 <+> d1

  display (w@(Abort t)) = do
    d <- dParen (precedence w) t
    return $ text "abort" <+> d

  display (Conv t pfs binding) = do
    lunbind binding $ \(vars,ty) -> do
      dVars <- mapM display vars
      dTy <- display ty
      dt <- display t
      dPfs <- mapM display pfs
      return $ fsep ([text "conv" <+> dt, text "by"] ++
                    (punctuate comma dPfs) ++
                    [text "at"] ++
                    dVars ++
                    [text ".", dTy])

  -- Context-style conversions
  display (ConvCtx t ctx) = do
    dt <- display t
    dctx <- display ctx
    return $ fsep [text "conv",nest 5 dt,text "at",nest 3 dctx]


  display (Escape t) = do
    dt <- display t
    return $ text "~" <> dt


  display (t@(Ord t0)) = do
    d0 <- termParen (precedence t) t0
    return $ text "ord" <+> d0

  display (t@(OrdTrans t0 t1)) = do
    d0 <- termParen (precedence t) t0
    d1 <- termParen (precedence t) t1
    return $ text "ordtrans" <+> d0 <+> d1


  display (t@(IndLT t0 t1)) = do
     d0 <- dParen (precedence t) t0
     d1 <- dParen (precedence t) t1
     return (d0 <+> text "<" <+> d1)



  display (Ind binding) = do
   lunbind binding $ \((f,tele,u),body) -> do
     df <- display f
     -- dx <- display x
     -- dTy <- display ty
     dtele <- display tele
     dBody <- display body
     du <- display u
     return $
      fsep [text "ind" <+> df <+> dtele <+>
           brackets du <+> text ".",
           nest 2 dBody]


  display (Rec binding) = do
    lunbind binding $ \((f,tele),body) -> do
      df <- display f
      dtele <- display tele
      dBody <- display body
      return $
         sep [text "rec" <+> df <+> dtele <+>
              text ".",
              nest 2 dBody]


  display (t@(Let binding)) = do
    (ds,body) <- linearizeLet t
    let f (x,y,Embed z) =
         do dx <- display x
            dy <- display y
            dz <- display z
            return(sep [dx <+> brackets dy <+> text "=",nest 3 dz])
    docs <- mapM f ds
    db <- display body
    return $ sep
      [text "let" <+> nest 4 (sep (punctuate (text ";") docs)), text "in" <+> db]


  display (t@(Aborts c)) = do
    dc <- dParen (precedence t) c
    return $ text "aborts" <+> dc
  display (t@(Ann t0 t1)) = do
    d0 <- dParen (precedence t) t0
    d1 <- dParen (precedence t) t1
    return $ fsep [d0, colon, nest 2 d1]


  display (Pos _ t) = display t
  display (t@(Sym x)) = do
    dx <- dParen (precedence t) x
    return $ text "sym" <+> dx
  display (t@Refl) = return $ text "refl"
  display t@(Trans t1 t2) = do
    d1 <- dParen (precedence t) t1
    d2 <- dParen (precedence t) t2
    return $ text "trans" <+> d1 <+> d2

  display t@(MoreJoin xs) = do
    ds <- mapM display xs
    return $ text "morejoin" <+> braces (hcat (punctuate comma ds))

  -- display e = error $ "display: " ++ show e

  precedence (Pos _ t) = precedence t
  precedence (Var _) = 12
  precedence (Con _) = 12
  precedence (Type) = 12
  precedence (Escape _) = 11
  precedence (App _ _ _) = 10
  precedence (Equal _ _) = 9
  precedence (IndLT _ _) = 8
  precedence (Terminates _) = 7
  precedence (Ann _ _) = 6

  precedence (Contra _) = 5
  precedence (Val _ ) = 5
  precedence (ContraAbort _ _) = 5
  precedence (Ord _) = 5
  precedence (OrdTrans _ _) = 5
  precedence (Aborts _) = 5
  precedence (Sym _) = 5
  precedence (Trans _ _) = 5
  precedence Refl = 5

  precedence (Pi Dynamic _) = 4
  precedence (Pi Static _) = 4
  precedence _ = 0


linearizeLet (Pos _ t) = linearizeLet t
linearizeLet (Let binding) =
  lunbind binding $ \(triple,body) -> do
     (ds,b) <- linearizeLet body
     return(triple:ds,b)
linearizeLet x = return ([],x)

-- bindingWrap adds the correct stage annotation for an abstraction binding.
bindingWrap Dynamic = parens
bindingWrap Static = brackets

instance Display Decl where
  display (ProgDecl n ty val) = do
    dn <- display n
    dty <- display ty
    dval <- display val
    return $ text "type" <+> dn <+> text ":" <+> dty <> semi $$
             cat[text "prog" <+> dn <+> text "=", nest 3 $ dval <> semi] $$ text ""


  display (ProofDecl n ty val) = do
    dn <- display n
    dty <- display ty
    dval <- display val
    return $ text "theorem" <+> dn <+> text ":" <+> dty <> semi $$
             cat[text "proof" <+> dn <+> text "=",nest 3 $ dval <> semi] $$ text ""

  display (AxiomDecl n ty) = do
    dn <- display n
    dty <- display ty
    return $ text "axiom" <+> dn <+> text ":" <+> dty <> semi


  display (DataDecl t1 binding) = do
    lunbind binding $ \(tele,cs) -> do
     d1 <- display t1
     -- d2 <- display t2
     dtele <- displayTele tele
     dcs <- mapM displayCons cs
     return $ hang (text "data" <+> d1 <+> colon <+> dtele <+> text "where") 2
                       (vcat (punctuate semi dcs)) $$ text ""
    where displayCons (c,t) = do
            dc <- display c
            dt <- display t
            return $ dc <+> colon <+> dt


          displayTele Empty = return $ text "Type"
          displayTele tele = do
             dtele <- display tele
             return $ dtele <+> text "-> Type"




instance Display Module where
  display (Module n bindings) = do
    dn <- display n
    dbindings <- mapM display bindings
    return $ text "module" <+> dn <+> text "where" $$
             cat dbindings


instance Display a => Display (Embed a) where
  display (Embed e) = display e



instance Display EExpr where
  display (EVar v) = display v
  display (ECon c) = display c
  display EType = return $ text "Type"
  display t@(EApp t1 t2) = do
     d1 <- etermParen (precedence t - 1) t1
     d2 <- etermParen (precedence t) t2
     return $ d1 <+> d2
  display t@(ERec binding) = do
    lunbind binding $ \((f,args),body) -> do
    df <- display f
    dx <- mapM display args
    dbody <- etermParen (precedence t) body
    -- return $ text "rec" <+> df <+> (hcat dx) <+> text "." <+> dbody
    return df

  display t@(ELambda binding) =  do
    lunbind binding $ \(x,body) -> do
    dx <- display x
    dbody <- etermParen (precedence t) body
    return $ fsep [text "\\" <+> dx <+> text ".",nest 2 dbody]

  display t@(ECase s alts) = do
    ds <- display s
    alts <- mapM displayAlt alts
    return $ text "case" <+> ds <+> text "of" $$
             nest 2 (vcat alts)
   where displayAlt alt = do
           lunbind alt $ \((c,pvars),body) -> do
           dbody <- display body
           dpvars <- mapM display pvars
           return $ fsep $ [text c <+> hsep dpvars <+> text "->", nest 2 dbody]

  display t@(ELet binding) = do
     lunbind binding $ \((n,t),body) -> do
     dn <- display n
     dt <- display t
     dbody <- display body
     return $ text "let" <+> dn <+> text "=" <+> dt $$
              text "in" <+> dbody
  display t@(EPi stage binding) = do
     lunbind binding $ \((n,t),body) -> do
     dn <- display n
     dt <- display t
     dbody <- display body
     return $ bindingWrap stage (dn <+> colon <+> dt) <+> text "->" <+> dbody



  precedence (EVar _) = 12
  precedence (ECon _) = 12
  precedence (EApp _ _) = 10
  precedence (ERec _) = 0
  precedence (ELambda _) = 0
  precedence (ECase _ _) = 1



etermParen:: (Display a) => Int -> a -> M Doc
etermParen level x
  | level >= (precedence x) = parens <$> display x
  | otherwise =  display x


-- instance Show TypeError where
--     show e = render $ display e



-- runDisplay t = render $ runFreshM (display t)

instance Disp Stage where
  disp Static = text "static"
  disp Dynamic = text "runtime"

instance Disp SourcePos where
  disp sp =  text (sourceName sp) <> colon <> int (sourceLine sp) <> colon <> int (sourceColumn sp) <> colon

instance Disp ParseError where
 disp pe = do
    hang (disp (errorPos pe)) 2
             (text "Parse Error:" $$ sem)
  where sem = text $ showErrorMessages "or" "unknown parse error"
              "expecting" "unexpected" "end of input"
              (errorMessages pe)



instance Display Tele where
    display Empty = return empty
    display (TCons binding) = do
      let ((n,stage,Embed ty),tele) = unrebind binding
      dn <- display n
      dty <- display ty
      drest <- display tele
      case stage of
        Static -> return $ brackets (dn <> colon <> dty) <> drest
        Dynamic -> return $ parens (dn <> colon <> dty) <> drest





