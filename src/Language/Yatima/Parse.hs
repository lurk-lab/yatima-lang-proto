{-|
Module      : Language.Yatima.Parse
Description : Parsing expressions in the Yatima Language
Copyright   : (c) Sunshine Cybernetics, 2020
License     : AGPL-3
Maintainer  : john@sunshinecybernetics.com
Stability   : experimental
-}
module Language.Yatima.Parse 
  ( ParseErr(..)
  , Parser
  , parseDefault
  , parserTest
  , parse'
  , pName
  , pLam
  , pVar
  , pTerm
  , pExpr
  , pFile
--  , prettyFile
  ) where

import           Codec.Serialise
import           Control.Monad.Except
import           Control.Monad.Identity
import           Control.Monad.RWS.Lazy     hiding (All)

import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Map                   (Map)
import qualified Data.Map                   as M
import           Data.Char                  (isDigit)
import qualified Data.Text.IO               as TIO

import           System.Exit

import           Text.Megaparsec            hiding (State)
import           Text.Megaparsec.Char       hiding (space)
import qualified Text.Megaparsec.Char.Lexer as L

import           Language.Yatima.Term
import           Language.Yatima.Print
import           Language.Yatima.Defs

-- | The environment of a Parser
data ParseEnv = ParseEnv
  { -- | The binding context for local variables
    _context :: [Name]
  , _defs    :: Defs
  }

-- | An empty parser environment, useful for testing
defaultParseEnv = ParseEnv [] emptyDefs

-- | Custom parser errrors with bespoke messaging
data ParseErr
  = UndefinedReference Name
  | TopLevelRedefinition Name
  | ReservedKeyword Name
  | LeadingDigit Name
  | LeadingApostrophe Name
  | CorruptDefs DerefErr
  deriving (Eq, Ord,Show)

instance ShowErrorComponent ParseErr where
  showErrorComponent (UndefinedReference nam) =
    "Undefined reference: " ++ T.unpack nam
  showErrorComponent (TopLevelRedefinition nam) =
    "illegal redefinition of " ++ T.unpack nam
  showErrorComponent (ReservedKeyword nam) =
    "Reserved keyword: " ++ T.unpack nam
  showErrorComponent (LeadingDigit nam) = 
    "illegal leading digit in name: " ++ T.unpack nam
  showErrorComponent (LeadingApostrophe nam) =
    "illegal leading apostrophe in name: " ++ T.unpack nam
  showErrorComponent (CorruptDefs e) =
    "ERR: The defined environment is corrupt: " ++ show e

-- | The type of the Yatima Parser
type Parser = RWST ParseEnv () () (ParsecT ParseErr Text Identity)

-- | A top level parser with default env and state
parseDefault :: Show a => Parser a -> Text
             -> Either (ParseErrorBundle Text ParseErr) a
parseDefault p s = do
  (a,_,_) <- runIdentity $ runParserT (runRWST p defaultParseEnv ()) "" s
  return a

-- | A useful testing function
parserTest :: Show a => Parser a -> Text -> IO ()
parserTest p s = case parseDefault p s of
  Left  e -> putStr (errorBundlePretty e)
  Right x -> print x

-- | A utility for running a `Parser`, since the `RWST` monad wraps `ParsecT`
parse' :: Show a => Parser a -> ParseEnv -> String -> Text
       -> Either (ParseErrorBundle Text ParseErr) a
parse' p env file txt = do
  (a,_,_) <- runIdentity $ runParserT (runRWST p env ()) file txt
  return a

pName :: Parser Text
pName = label "a name: \"someFunc\",\"somFunc'\",\"x_15\", \"_1\"" $ do
  n  <- alphaNumChar <|> oneOf nameSymbol
  ns <- many (alphaNumChar <|> oneOf nameSymbol)
  let nam = T.pack (n : ns)
  if | isDigit n                -> customFailure $ LeadingDigit nam
     | n == '\''                -> customFailure $ LeadingApostrophe nam
     | nam `elem` reservedWords -> customFailure $ ReservedKeyword nam
     | otherwise -> return nam
  where
    nameSymbol = "_'" :: [Char]

    reservedWords :: [Text]
    reservedWords = [ "let"
                    , "if"
                    , "then"
                    , "else"
                    , "where"
                    , "case"
                    , "lam"
                    , "lambda"
                    , "def"
                    ]

-- | Consume whitespace, while skipping comments. Yatima line comments begin
-- with @//@, and block comments are bracketed by @*/@ and @*/@ symbols.
space :: Parser ()
space = L.space space1 (L.skipLineComment "--") (L.skipBlockComment "/*" "*/")

-- | A symbol is a string which can be followed by whitespace. The @sc@ argument
-- is for parsing indentation sensitive whitespace
symbol :: Text -> Parser Text
symbol txt = L.symbol space txt

-- | Add a list of names to the binding context
bind :: [Name] -> Parser a -> Parser a
bind bs p = local (\e -> e { _context = (reverse bs) ++ _context e }) p

-- | Find a name in the binding context and return its index
find :: Name -> [Name] -> Maybe Int
find n cs = go n cs 0
  where
    go n (c:cs) i
      | n == c    = Just i
      | otherwise = go n cs (i+1)
    go _ [] _     = Nothing

foldLam:: Term -> [Name] -> Term
foldLam body bs = foldr (\n x -> Lam n x) body bs

-- | Parse a lambda: @λ (x) (y) (z) => body@
pLam :: Parser Term
pLam = label "a lambda: \"λ (x) (y) => y\"" $ do
  symbol "λ" <|> symbol "lam" <|> symbol "lambda"
  bs   <- pBinder1 <* space
  symbol "=>"
  body <- bind bs (pExpr False)
  return $ foldLam body bs

---- | Parse an untyped binding sequence @x y z@ within a lambda
pBinder1 :: Parser [Name]
pBinder1 = label "a single binder in lambda" $ do
  --symbol "("
  names <- sepEndBy1 pName space
  --string ")"
  return names

pBinder :: Parser [Name]
pBinder = label "a single binder in lambda" $ do
  --symbol "("
  names <- sepEndBy pName space
  --string ")"
  return names

-- TODO: Use this when adding types to lambdas (if desired in future)
--pBinders :: Parser [Name]
--pBinders = label "a binding sequence in a lambda" $ do
--  (try $ next) <|> pBinder
--  where
--   next = do
--     b  <- pBinder <* space
--     bs <- bind b $ pBinders
--     return $ b ++ bs

-- | Parse a local variable or a locally indexed alias of a global reference
pVar :: Parser Term
pVar = label "a local or global reference: \"x\", \"add\"" $ do
  ctx <- asks _context
  nam <- pName
  case find nam ctx of
    Just i  -> return $ Var nam i
    Nothing -> do
      Defs index cache <- asks _defs
      case M.lookup nam index of
        Nothing  -> customFailure $ UndefinedReference nam
        Just _   -> return $ Ref nam

-- | Parse a term
pTerm :: Parser Term
pTerm = do
  choice
    [ pLam
    , pExpr True
    , pVar
    ]

-- | Parse a sequence of terms as an expression
pExpr :: Bool -> Parser Term
pExpr parens = do
  when parens (void $ symbol "(")
  fun  <- pTerm <* space
  args <- sepEndBy (try $ pTerm) space
  when parens (void $ string ")")
  return $ foldl (\t a -> App t a) fun args

pDecl :: Bool -> Parser (Name, Term)
pDecl shadow = do
  nam     <- pName <* space
  index   <- asks (_index . _defs)
  when (not shadow && M.member nam index)
    (customFailure $ TopLevelRedefinition nam)
  bs      <- pBinder <* space
  --typBody <- symbol ":" >> bind (fst <$> bs) (pExpr False)
  --typUpto <- getOffset
  --let typ = foldAll (Loc from typUpto) typBody bs
  symbol "="
  expBody <- bind (nam:bs) $ pExpr False
  let exp = foldLam expBody bs
  return (nam, exp)

-- | Parse a definition
pDef :: Parser Def
pDef = label "a definition" $ do
  symbol "def"
  (nam,exp) <- pDecl False
  return $ Def nam exp exp -- placeholder for type-level

sepMeta :: Name -> Term -> Parser (Anon,Meta)
sepMeta name term = do
  defs <- asks _defs
  case runExcept (separateMeta name term defs) of
    Left  e -> customFailure $ CorruptDefs e
    Right x -> return x

-- | Parse a sequence of definitions, e.g. in a file
pDefs :: Parser Defs
pDefs = (try $ space >> next) <|> end
  where
  end = space >> eof >> asks _defs
  next = do
    ds@(Defs index cache) <- asks _defs
    Def name term typ_ <- pDef
    (termAnon, termMeta) <- sepMeta name term
    (typeAnon, typeMeta) <- sepMeta name term
    let termAnonCID = makeCID termAnon :: CID
    let typeAnonCID = makeCID typeAnon :: CID
    let anonDef     = AnonDef termAnonCID typeAnonCID
    let anonDefCID  = makeCID anonDef :: CID
    let metaDef     = MetaDef anonDefCID termMeta typeMeta
    let metaDefCID  = makeCID metaDef :: CID
    let index'      = M.insert name        metaDefCID           $ index
    let cache'      = M.insert metaDefCID  (serialise metaDef)  $
                      M.insert anonDefCID  (serialise anonDef)  $
                      M.insert typeAnonCID (serialise typeAnon) $
                      M.insert termAnonCID (serialise termAnon) $
                      cache
    local (\e -> e { _defs = Defs index' cache' }) pDefs

-- | Parse a file
pFile :: FilePath -> IO Defs
pFile file = do
  txt <- TIO.readFile file
  case parse' pDefs defaultParseEnv file txt of
    Left  e -> putStr (errorBundlePretty e) >> exitFailure
    Right m -> return m

---- | Parse and pretty-print a file
--prettyFile :: FilePath -> IO ()
--prettyFile file = do
--  term <- pFile file
--  putStrLn $ T.unpack $ prettyTerm term
