{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module DB
    ( module X
    , DataLayer (..)
    , stubbedDataLayer
    , postgresqlDataLayer
    -- * Examples
    , stubbedInitialDataMap
    , stubbedBlacklistedPools
    ) where

import           Cardano.Prelude

import           Control.Monad.Trans.Except.Exit (orDie)
import           Control.Monad.Trans.Except.Extra (newExceptT)

import           Data.Aeson (eitherDecode')
import qualified Data.Map as Map
import           Data.IORef (IORef, readIORef, modifyIORef)

import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL

import           Types

import           Cardano.Db.Insert (insertTxMetadata)
import           Cardano.Db.Query (DBFail (..), queryTxMetadata)

import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Hash.Blake2b as Crypto

import qualified Data.ByteString.Base16 as B16

import           Cardano.Db.Migration as X
import           Cardano.Db.Migration.Version as X
import           Cardano.Db.PGConfig as X
import           Cardano.Db.Run as X
import           Cardano.Db.Schema as X
import           Cardano.Db.Error as X

-- | This is the data layer for the DB.
-- The resulting operation has to be @IO@, it can be made more granular,
-- but currently there is no complexity involved for that to be a sane choice.
data DataLayer = DataLayer
    { dlGetPoolMetadataSimple   :: PoolHash -> IO (Either DBFail Text)
    , dlGetPoolMetadata         :: PoolHash -> IO (Either DBFail PoolOfflineMetadata)
    , dlAddPoolMetadata         :: PoolHash -> PoolOfflineMetadata -> IO (Either DBFail PoolOfflineMetadata)
    , dlAddPoolMetadataSimple   :: PoolHash -> Text -> IO (Either DBFail TxMetadataId)
    , dlGetBlacklistedPools     :: IO (Either DBFail [PoolHash])
    , dlAddBlacklistedPool      :: PoolHash -> IO (Either DBFail PoolHash)
    }

-- | Simple stubbed @DataLayer@ for an example.
-- We do need state here. _This is thread safe._
-- __This is really our model here.__
stubbedDataLayer
    :: IORef (Map PoolHash PoolOfflineMetadata)
    -> IORef [PoolHash]
    -> DataLayer
stubbedDataLayer ioDataMap ioBlacklistedPool = DataLayer
    { dlGetPoolMetadata     = \poolHash -> do
        ioDataMap' <- readIORef ioDataMap
        case (Map.lookup poolHash ioDataMap') of
            Just poolOfflineMetadata'   -> return $ Right poolOfflineMetadata'
            Nothing                     -> return $ Left (DbLookupTxMetadataHash (encodeUtf8 $ getPoolHash poolHash))

    , dlGetPoolMetadataSimple = \poolHash -> panic "To implement!"

    , dlAddPoolMetadata     = \poolHash poolMetadata -> do
        -- TODO(KS): What if the pool metadata already exists?
        _ <- modifyIORef ioDataMap (\dataMap -> Map.insert poolHash poolMetadata dataMap)
        return $ Right poolMetadata

    -- TODO(KS): To speed up development.
    , dlAddPoolMetadataSimple = panic "To implement!"

    , dlGetBlacklistedPools = do
        blacklistedPool <- readIORef ioBlacklistedPool
        return $ Right blacklistedPool

    , dlAddBlacklistedPool  = \poolHash -> do
        _ <- modifyIORef ioBlacklistedPool (\pool -> [poolHash] ++ pool)
        -- TODO(KS): Do I even need to query this?
        blacklistedPool <- readIORef ioBlacklistedPool
        return $ Right poolHash
    }

-- The approximation for the table.
stubbedInitialDataMap :: Map PoolHash PoolOfflineMetadata
stubbedInitialDataMap = Map.fromList
    [ (createPoolHash "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc", examplePoolOfflineMetadata)
    ]

-- The approximation for the table.
stubbedBlacklistedPools :: [PoolHash]
stubbedBlacklistedPools = []

postgresqlDataLayer :: DataLayer
postgresqlDataLayer = DataLayer
    { dlGetPoolMetadata     = \poolHash -> panic "To implement!"

    , dlGetPoolMetadataSimple = \poolHash -> do
        txMetadata <- runDbAction Nothing $ queryTxMetadata (encodeUtf8 $ getPoolHash poolHash)
        return (txMetadataMetadata <$> txMetadata)

    , dlAddPoolMetadata     = \poolHash poolMetadata -> panic "To implement!"

    , dlAddPoolMetadataSimple     = \poolHash poolMetadata -> do

        let poolOfflineMetadataByteString = BL.fromStrict . encodeUtf8 $ poolMetadata

        -- Let us try to decode the contents to JSON.
        let decodedPoolMetadataJSON :: Either DBFail PoolOfflineMetadata
            decodedPoolMetadataJSON = case (eitherDecode' poolOfflineMetadataByteString) of
                Left err -> Left $ UnableToEncodePoolMetadataToJSON $ toS err
                Right result -> return result

        -- If unable to decode into JSON object, fails!
        _ <- orDie (\e -> renderLookupFail e) (newExceptT $ pure decodedPoolMetadataJSON)

        let poolHashBytestring = encodeUtf8 $ getPoolHash poolHash
        let hashFromMetadata = B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) (encodeUtf8 poolMetadata)

        if hashFromMetadata /= poolHashBytestring
            then return $ Left PoolMetadataHashMismatch
            else fmap Right $ runDbAction Nothing $ insertTxMetadata $ TxMetadata poolHashBytestring poolMetadata

    , dlGetBlacklistedPools = panic "To implement!"
    , dlAddBlacklistedPool  = \poolHash -> panic "To implement!"
    }
