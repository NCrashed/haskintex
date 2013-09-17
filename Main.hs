
{-# LANGUAGE OverloadedStrings #-}

-- System
import System.Process
import System.Environment (getArgs)
import System.FilePath
import System.Directory
-- Text
import Data.Text (Text,pack,unpack)
import qualified Data.Text as T
import qualified Data.Text.IO as T
-- Parser
import Data.Attoparsec.Text
-- Transformers
import Control.Monad (when)
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
-- LaTeX
import Text.LaTeX
-- Utils
import Control.Applicative
import Data.Foldable (foldMap)

data Syntax =
    WriteLaTeX   Text
  | WriteHaskell Bool Text -- False for Hidden, True for Visible
  | EvalHaskell  Bool Text -- False for Command, True for Environment
  | Sequence     [Syntax]
    deriving Show

extractCode :: Syntax -> Text
extractCode (WriteHaskell _ t) = t
extractCode (Sequence xs) = foldMap extractCode xs
extractCode _ = mempty

parseSyntax :: Bool -> Parser Syntax
parseSyntax v = fmap Sequence $ many $ choice [ p_writehaskell v, p_evalhaskell, p_writelatex ]

p_writehaskell :: Bool -> Parser Syntax
p_writehaskell v = do
  string "\\begin{writehaskell}"
  b <- choice [ string "[hidden]"  >> return False
              , string "[visible]" >> return True
              , return v ]
  h <- manyTill anyChar $ try $ string "\\end{writehaskell}"
  return $ WriteHaskell b $ pack h

p_evalhaskell :: Parser Syntax
p_evalhaskell = choice [ p_evalhaskellenv, p_evalhaskellcomm ]

p_evalhaskellenv :: Parser Syntax
p_evalhaskellenv = do
  string "\\begin{evalhaskell}"
  h <- manyTill anyChar $ try $ string "\\end{evalhaskell}"
  return $ EvalHaskell True $ pack h

p_evalhaskellcomm :: Parser Syntax
p_evalhaskellcomm = do
  string "\\evalhaskell{"
  h <- manyTill anyChar $ char '}'
  return $ EvalHaskell False $ pack h

p_writelatex :: Parser Syntax
p_writelatex = (WriteLaTeX . pack) <$>
  many1 (p_other >>= \b -> if b then anyChar else fail "stop write latex")
  where
    p_other =
      choice [ string "\\begin{writehaskell}" >> return False
             , string "\\begin{evalhaskell}"  >> return False
             , string "\\evalhaskell"         >> return False
             , return True
             ]

moduleHeader :: String -> Text -> Text
moduleHeader str t = pack ("module " ++ str ++ " where\n\n") <> t

-- Evaluation

evalCode :: String -> Syntax -> Haskintex Text
evalCode modName = go
  where
    go (WriteLaTeX t) = return t
    go (WriteHaskell b t) =
         return $ if b then render (verbatim t :: LaTeX)
                       else mempty
    go (EvalHaskell b t) =
         let f :: Text -> LaTeX
             f = if b then verbatim . layout else verb
         in (render . f . pack) <$> ghc modName t
    go (Sequence xs) = mconcat <$> mapM go xs

ghc :: String -> Text -> Haskintex String
ghc modName e = do
  let e' = unpack $ T.strip e
  outputStr $ "Evaluation: " ++ e'
  lift $ init <$> readProcess "ghc" [ "-e", e', modName ++ ".hs" ] []

maxLineLength :: Int
maxLineLength = 60

-- | Break lines longer than 'maxLineLenght'.
layout :: Text -> Text
layout = T.unlines . go . T.lines
  where
    go [] = []
    go (t:ts) =
      if T.length t > maxLineLength
         then let (l,r) = T.splitAt maxLineLength t
              in  l : go (r:ts)
         else t : go ts

-- Configuration

data Conf = Conf
  { keepFlag :: Bool
  , visibleFlag :: Bool
  , verboseFlag :: Bool
  , inputs :: [FilePath]
    }

isArg :: String -> Bool
isArg [] = False
isArg (x:_) = x == '-'

readConf :: [String] -> Conf
readConf xs =
  Conf ("-keep" `elem` xs)
       ("-visible" `elem` xs)
       ("-verbose" `elem` xs)
       (filter (not . isArg) xs)

-- Haskintex

type Haskintex = ReaderT Conf IO

outputStr :: String -> Haskintex ()
outputStr str = do
  b <- verboseFlag <$> ask
  when b $ lift $ putStrLn str

-- MAIN

main :: IO ()
main = (readConf <$> getArgs) >>= runReaderT haskintex

haskintex :: Haskintex ()
haskintex = ask >>= mapM_ haskintexFile . inputs

haskintexFile :: FilePath -> Haskintex ()
haskintexFile fp = do
  outputStr $ "Reading " ++ fp ++ "..."
  t <- lift $ T.readFile fp
  vFlag <- visibleFlag <$> ask
  case parseOnly (parseSyntax vFlag) t of
    Left err -> outputStr $ "Reading of " ++ fp ++ " failed: " ++ err
    Right s -> do
      let modName = ("Haskintex_" ++) $ dropExtension $ takeFileName fp
      outputStr $ "Creating " ++ modName ++ " module..."
      let hs = extractCode s
      lift $ T.writeFile (modName ++ ".hs") $ moduleHeader modName hs
      outputStr $ "Evaluating expressions in " ++ fp ++ "..."
      l <- evalCode modName s
      let fp' = "haskintex_" ++ fp
      outputStr $ "Writing final file at " ++ fp' ++ "..."
      lift $ T.writeFile fp' l
      kFlag <- keepFlag <$> ask
      when (not kFlag) $ do
        outputStr $ "Removing Haskell Source file " ++ modName ++ ".hs..."
        lift $ removeFile $ modName ++ ".hs"
      outputStr $ "End of processing of file " ++ fp ++ "."
