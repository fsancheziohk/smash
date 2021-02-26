{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module Cardano.SMASH.API
    ( API
    , fullAPI
    , smashApi
    ) where

import           Cardano.Prelude
import           Prelude                       (String)

import           Data.Aeson                    (FromJSON, ToJSON (..),
                                                eitherDecode, encode, object,
                                                (.=))
import           Data.Swagger                  (Swagger (..))

import           Network.Wai                   (Request, lazyRequestBody)
import           Servant                       ((:<|>) (..), (:>), BasicAuth,
                                                Capture, Get, HasServer (..),
                                                Header, Headers, JSON,
                                                OctetStream, Patch, Post,
                                                QueryParam, ReqBody)
import           Servant.Server                (err400)
import           Servant.Server.Internal       (DelayedIO, addBodyCheck,
                                                delayedFailFatal, errBody,
                                                withRequest)

import           Servant.Swagger               (HasSwagger (..))

import           Cardano.SMASH.DBSync.Db.Error (DBFail (..))
import           Cardano.SMASH.Types           (ApiResult, HealthStatus,
                                                PoolFetchError, PoolId (..),
                                                PoolId, PoolIdBlockNumber (..),
                                                PoolMetadataHash,
                                                PoolMetadataRaw, TickerName,
                                                TimeStringFormat, User)


-- Showing errors as JSON. To be reused when we need more general error handling.

data Body a

instance (FromJSON a, HasServer api context) => HasServer (Body a :> api) context where
  type ServerT (Body a :> api) m = a -> ServerT api m

  route Proxy context subserver =
      route (Proxy :: Proxy api) context (addBodyCheck subserver ctCheck bodyCheckRequest)
    where
      -- Don't check the content type specifically.
      ctCheck :: DelayedIO Request
      ctCheck = withRequest $ \req -> pure req

      bodyCheckRequest :: Request -> DelayedIO a
      bodyCheckRequest request = do
        body <- liftIO (lazyRequestBody request)
        case eitherDecode body of
          Left dbFail ->
            delayedFailFatal err400 { errBody = encode dbFail }
          Right v ->
            return v

newtype BodyError = BodyError String
instance ToJSON BodyError where
    toJSON (BodyError b) = object ["error" .= b]

-- |For api versioning.
type APIVersion = "v1"

-- | Shortcut for common api result types.
type ApiRes verb a = verb '[JSON] (ApiResult DBFail a)

-- The basic auth.
type BasicAuthURL = BasicAuth "smash" User

-- GET api/v1/status
type HealthStatusAPI = "api" :> APIVersion :> "status" :> ApiRes Get HealthStatus

-- GET api/v1/metadata/{hash}
type OfflineMetadataAPI = "api" :> APIVersion :> "metadata" :> Capture "id" PoolId :> Capture "hash" PoolMetadataHash :> Get '[JSON] (Headers '[Header "Cache-Control" Text] (ApiResult DBFail PoolMetadataRaw))

-- GET api/v1/delisted
type DelistedPoolsAPI = "api" :> APIVersion :> "delisted" :> ApiRes Get [PoolId]

-- GET api/v1/errors
type FetchPoolErrorAPI = "api" :> APIVersion :> "errors" :> Capture "poolId" PoolId :> QueryParam "fromDate" TimeStringFormat :> ApiRes Get [PoolFetchError]

#ifdef DISABLE_BASIC_AUTH
-- POST api/v1/delist
type DelistPoolAPI = "api" :> APIVersion :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = "api" :> APIVersion :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#else
type DelistPoolAPI = BasicAuthURL :> "api" :> APIVersion :> "delist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId

type EnlistPoolAPI = BasicAuthURL :> "api" :> APIVersion :> "enlist" :> ReqBody '[JSON] PoolId :> ApiRes Patch PoolId
#endif

type RetiredPoolsAPI = "api" :> APIVersion :> "retired" :> ApiRes Get [PoolId]

type CheckPoolAPI = "api" :> APIVersion :> "exists" :> Capture "poolId" PoolId :> ApiRes Get PoolId

-- The full API.
type SmashAPI =  OfflineMetadataAPI
            :<|> HealthStatusAPI
            :<|> DelistedPoolsAPI
            :<|> DelistPoolAPI
            :<|> EnlistPoolAPI
            :<|> FetchPoolErrorAPI
            :<|> RetiredPoolsAPI
            :<|> CheckPoolAPI
#ifdef TESTING_MODE
            :<|> RetirePoolAPI
            :<|> AddPoolAPI
            :<|> AddTickerAPI

type RetirePoolAPI = "api" :> APIVersion :> "retired" :> ReqBody '[JSON] PoolIdBlockNumber :> ApiRes Patch PoolId
type AddPoolAPI = "api" :> APIVersion :> "metadata" :> Capture "id" PoolId :> Capture "hash" PoolMetadataHash :> ReqBody '[OctetStream] PoolMetadataRaw :> ApiRes Post PoolId
type AddTickerAPI = "api" :> APIVersion :> "tickers" :> Capture "name" TickerName :> ReqBody '[JSON] PoolMetadataHash :> ApiRes Post TickerName

#endif

-- | API for serving @swagger.json@.
type SwaggerAPI = "swagger.json" :> Get '[JSON] Swagger

-- | Combined API of a Todo service with Swagger documentation.
type API = SwaggerAPI :<|> SmashAPI

fullAPI :: Proxy API
fullAPI = Proxy

-- | Just the @Proxy@ for the API type.
smashApi :: Proxy SmashAPI
smashApi = Proxy

-- For now, we just ignore the @Body@ definition.
instance (HasSwagger api) => HasSwagger (Body name :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

-- For now, we just ignore the @BasicAuth@ definition.
instance (HasSwagger api) => HasSwagger (BasicAuth name typo :> api) where
    toSwagger _ = toSwagger (Proxy :: Proxy api)

