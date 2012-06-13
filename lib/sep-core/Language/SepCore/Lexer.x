
{
module Language.SepCore.Lexer where
import Language.SepCore.PrettyPrint
import Text.PrettyPrint
}

%wrapper "monad"

$digit = 0-9		
$alpha = [a-zA-Z]	

@num = $digit+
@proofVar = "$" $alpha [$alpha $digit \_ \']*
@termVar = $alpha [$alpha $digit \_ \']*
@predVar = "&" $alpha [$alpha $digit \_ \']*
@comments =  "--".* 

@reservedWords = data | Data | where | Where | type | Type | Formula | formula
                | Bottom | bottom | pi | Pi | Eq | eq | Forall | forall | abort | Abort
                | join | Join | contr | Contr | valax | Valax | Case | case | of | Of | Let
                | let | in | In | rec | Rec | conv | Conv | by | By

@reservedSymbols = \\ | "!" | "(" | ")" | "{" | "}" | "::" | ":" | "+" | "-" | ":="
                  | "." | "|" | "->" | "=" | "[" | "]" | "," | "@"
tokens :-
-- Notice: the order of the following productions actually matters. Becase there is
-- a potential overlapping between termvar and reservedwords. So we need to scan reservedwords 
-- first, and then scan other variables.

       $white+				;
       @comments                        ;
       @num                             {lexNum}
       @reservedWords                   {lexReservedW}
       @proofVar                        {lexProofVar}
       @termVar                         {lexTermVar}
       @predVar                         {lexPredVar}
       @reservedSymbols                 {lexReservedS}
                    

 
{


-- The token type:

data Token =

       TokenType 

       | TokenDef

       | TokenInt Integer

       | TokenFm 

       | TokenForall
 
       | TokenProofVar String

       | TokenPredVar String

       | TokenTermVar String

       | TokenPi

       | TokenEq

       | TokenBot

       | TokenLamb

       | TokenJoin

       | TokenContr

       | TokenValax

       | TokenEx 

       | TokenBL 

       | TokenBR 

       | TokenDC 

       | TokenPlus

       | TokenMinus

       | TokenCL 

       | TokenDot

       | TokenAb 
 
       | TokenCBL

       | TokenCBR

       | TokenData

       | TokenWhere

       | TokenBar

       | TokenEOF

       | TokenOf

       | TokenCase

       | TokenArrow

       | TokenLet

       | TokenIn

       | TokenEquiv

       | TokenRec

       | TokenSQL

       | TokenSQR

       | TokenComma

       | TokenAp
       | TokenConv
       | TokenBy
  deriving (Show, Eq)

data Lexeme = L AlexPosn Token String


instance Disp Token where
	disp TokenType = text "Type"

        disp TokenDef = text ":="

        disp (TokenInt i) = integer i

        disp TokenFm = text "formula"

        disp TokenForall = text "forall"
 
        disp (TokenProofVar s) = text s

        disp (TokenPredVar s) = text s
        disp TokenData = text "data"

        disp TokenWhere = text "where"

        disp (TokenTermVar s) = text s

        disp TokenPi = text "Pi"

        disp TokenEq = text "Eq"

        disp TokenBot = text "bottom"

        disp TokenLamb = text "\\"

        disp TokenJoin = text "join"

        disp TokenContr = text "contra"

        disp TokenValax = text "valax"

        disp TokenEx = text "!"

        disp TokenBL = text "("

        disp TokenBR = text ")"

        disp TokenDC = text "::"

        disp TokenPlus = text "+"

        disp TokenMinus = text "-"

        disp TokenCL = text ":"

        disp TokenDot = text "."

        disp TokenAb = text "abort"
 
        disp TokenCBL = text "{"

        disp TokenCBR = text "}"

  
        disp TokenBar = text "|"

        disp TokenEOF = text "EOF"

        disp TokenOf = text "of"

        disp TokenCase = text "case"

        disp TokenArrow = text "->"

        disp TokenLet = text "let"

        disp TokenIn = text "in"

        disp TokenEquiv = text "="

        disp TokenRec = text "rec"
        disp TokenSQL = text "["
        disp TokenSQR = text "]"
        disp TokenComma = text ","
        disp TokenAp = text "@"
        disp TokenConv = text "conv"
        disp TokenBy = text "by"

mkL :: Token -> AlexInput -> Int -> Alex Lexeme
mkL t (p,_,str) len = return (L p t (take len str))

lexNum :: AlexInput -> Int -> Alex Lexeme
lexNum a@(_,_,input) len = mkL (TokenInt (read (take len input))) a len

lexProofVar :: AlexInput -> Int -> Alex Lexeme
lexProofVar a@(_,_,input) len = mkL (TokenProofVar (take len input)) a len

lexTermVar :: AlexInput -> Int -> Alex Lexeme
lexTermVar a@(_,_,input) len = mkL (TokenTermVar (take len input)) a len

lexPredVar :: AlexInput -> Int -> Alex Lexeme
lexPredVar a@(_,_,input) len = mkL (TokenPredVar (take len input)) a len

lexReservedW :: AlexInput -> Int -> Alex Lexeme
lexReservedW a@(_,_,input) len = case take len input of
                                    "data" -> mkL TokenData a len 
                                    "Data" -> mkL TokenData a len
                                    "where" -> mkL TokenWhere a len
                                    "Where" -> mkL TokenWhere a len
                                    "Type" -> mkL TokenType a len
                                    "type" -> mkL TokenType a len
                                    "formula" -> mkL TokenFm a len
                                    "Formula" -> mkL TokenFm a len
                                    "Bottom" -> mkL TokenBot a len
                                    "bottom" -> mkL TokenBot a len
                                    "pi" -> mkL TokenPi a len
                                    "Pi" -> mkL TokenPi a len
                                    "Eq" -> mkL TokenEq a len
                                    "eq" -> mkL TokenEq a len
                                    "forall" -> mkL TokenForall a len
                                    "Forall" -> mkL TokenForall a len
                                    "abort" -> mkL TokenAb a len
                                    "Abort" -> mkL TokenAb a len
                                    "Join" -> mkL TokenJoin a len
                                    "join" -> mkL TokenJoin a len
                                    "Contr" -> mkL TokenContr a len
                                    "contr" -> mkL TokenContr a len
                                    "valax" -> mkL TokenValax a len
                                    "Valax" -> mkL TokenValax a len
                                    "case" -> mkL TokenCase a len
                                    "Case" -> mkL TokenCase a len
                                    "Of" -> mkL TokenOf a len
                                    "of" -> mkL TokenOf a len
                                    "Let" -> mkL TokenLet a len
                                    "let" -> mkL TokenLet a len
                                    "in" -> mkL TokenIn a len
                                    "In" -> mkL TokenIn a len
                                    "rec" -> mkL TokenRec a len
                                    "Rec" -> mkL TokenRec a len
                                    "Conv" -> mkL TokenConv a len
                                    "conv" -> mkL TokenConv a len
                                    "by" -> mkL TokenBy a len
                                    "By" -> mkL TokenBy a len

-- @reservedSymbols = "\\" | "!" | "(" | ")" | "{" | "}" | "::" | ":" | "+" | "-" | ":="
--                  | "." | "|"

lexReservedS :: AlexInput -> Int -> Alex Lexeme
lexReservedS a@(_,_,input) len = case take len input of
                                    "\\" -> mkL TokenLamb a len 
                                    "!" -> mkL TokenEx a len
                                    "(" -> mkL TokenBL a len
                                    ")" -> mkL TokenBR a len
                                    "{" -> mkL TokenCBL a len
                                    "}" -> mkL TokenCBR a len
                                    "::" -> mkL TokenDC a len
                                    ":" -> mkL TokenCL a len
                                    "-" -> mkL TokenMinus a len
                                    "+" -> mkL TokenPlus a len
                                    ":=" -> mkL TokenDef a len
                                    "." -> mkL TokenDot a len
                                    "|" -> mkL TokenBar a len
                                    "->" -> mkL TokenArrow a len
                                    "=" -> mkL TokenEquiv a len
                                    "[" -> mkL TokenSQL a len
                                    "]" -> mkL TokenSQR a len
                                    "," -> mkL TokenComma a len
                                    "@" -> mkL TokenAp a len


getLineNum :: AlexPosn -> Int
getLineNum (AlexPn offset lineNum colNum) = lineNum 

getColumnNum :: AlexPosn -> Int
getColumnNum (AlexPn offset lineNum colNum) = colNum

alexMonadScan2 = do
  inp <- alexGetInput
  sc <- alexGetStartCode
  case alexScan inp sc of
    AlexEOF -> alexEOF
    AlexError inp'@(p,_,s) -> alexError $ show (getLineNum p) ++ ":" ++ show ((getColumnNum p)-1) ++ ": Lexical error."
    AlexSkip  inp' len -> do
        alexSetInput inp'
        alexMonadScan2
    AlexToken inp' len action -> do
        alexSetInput inp'
        action inp len

alexEOF = return (L undefined TokenEOF "")

{-
-- some unusable test code.

scanner str = runAlex str $ do
  let loop t = do tok@(L _ cl _) <- alexMonadScan2; 
		  if cl == TokenEOF
			then return t
			else do loop $! (t ++ [cl])
  loop []

test = do
  s <- getLine
  print (scanner s)

-}


}




