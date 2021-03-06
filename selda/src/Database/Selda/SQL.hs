{-# LANGUAGE GADTs, OverloadedStrings, ScopedTypeVariables, RecordWildCards #-}
{-# LANGUAGE TypeOperators, FlexibleInstances, UndecidableInstances #-}
-- | SQL AST and parameters for prepared statements.
module Database.Selda.SQL where
import Database.Selda.Exp
import Database.Selda.SqlType
import Database.Selda.Types
import Control.Exception
import Data.Monoid hiding (Product)
import System.IO.Unsafe

-- | A source for an SQL query.
data SqlSource
 = TableName !TableName
 | Product ![SQL]
 | Join !JoinType !(Exp SQL Bool) !SQL !SQL
 | Values ![SomeCol SQL] ![[Param]]
 | EmptyTable

-- | Type of join to perform.
data JoinType = InnerJoin | LeftJoin

-- | AST for SQL queries.
data SQL = SQL
  { cols      :: ![SomeCol SQL]
  , source    :: !SqlSource
  , restricts :: ![Exp SQL Bool]
  , groups    :: ![SomeCol SQL]
  , ordering  :: ![(Order, SomeCol SQL)]
  , limits    :: !(Maybe (Int, Int))
  }

instance Names SqlSource where
  allNamesIn (Product qs)   = concatMap allNamesIn qs
  allNamesIn (Join _ e l r) = allNamesIn e ++ concatMap allNamesIn [l, r]
  allNamesIn (Values vs _)  = allNamesIn vs
  allNamesIn (TableName _)  = []
  allNamesIn (EmptyTable)   = []

instance Names SQL where
  -- Note that we don't include @cols@ here: the names in @cols@ are not
  -- necessarily used, only declared.
  allNamesIn (SQL{..}) = concat
    [ allNamesIn groups
    , concatMap (allNamesIn . snd) ordering
    , allNamesIn restricts
    , allNamesIn source
    ]

-- | The order in which to sort result rows.
data Order = Asc | Desc
  deriving (Show, Ord, Eq)

-- | A parameter to a prepared SQL statement.
data Param where
  Param :: !(Lit a) -> Param

instance Show Param where
  show (Param l) = "Param " <> show l

instance Eq Param where
  Param a == Param b = compLit a b == EQ
instance Ord Param where
  compare (Param a) (Param b) = compLit a b

-- | Exception indicating the use of a default value.
--   If any values throwing this during evaluation of @param xs@ will be
--   replaced by their default value.
data DefaultValueException = DefaultValueException
  deriving Show
instance Exception DefaultValueException

-- | An inductive tuple of Haskell-level values (i.e. @Int :*: Maybe Text@)
--   which can be inserted into a table.
class Insert a where
  params :: a -> [Either Param Param]
instance (SqlType a, Insert b) => Insert (a :*: b) where
  params (a :*: b) = unsafePerformIO $ do
    res <- try $ return $! a
    return $ case res of
      Right a' ->
        Right (Param (mkLit a')) : params b
      Left DefaultValueException ->
        Left (Param (defaultValue :: Lit a)) : params b
instance {-# OVERLAPPABLE #-} SqlType a => Insert a where
  params a = unsafePerformIO $ do
    res <- try $ return $! a
    return $ case res of
      Right a' ->
        [Right $ Param (mkLit a')]
      Left DefaultValueException ->
        [Left $ Param (defaultValue :: Lit a)]
