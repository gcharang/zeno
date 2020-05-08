
module Zeno.Notariser.KMDETH where

import Network.Bitcoin
import Network.Ethereum
import Network.Komodo
import           Network.HTTP.Simple
import           Network.JsonRpc

import Zeno.Notariser.UTXO

import Zeno.EthGateway
import Zeno.Notariser.KMD
import Zeno.Notariser.Types
import Zeno.Consensus
import Zeno.Config
import Zeno.Prelude
import Zeno.Prelude.Lifted



consensusTimeout :: Int
consensusTimeout = 5 * 1000000



runNotariseKmdToEth :: GethConfig -> ConsensusNetworkConfig -> Address -> FilePath -> RAddress -> IO ()
runNotariseKmdToEth gethConfig consensusConfig gateway kmdConfPath kmdAddress = do
  threadDelay 1000000
  bitcoinConf <- loadBitcoinConfig kmdConfPath
  wif <- runZeno bitcoinConf $ queryBitcoin "dumpprivkey" [kmdAddress]
  sk <- either error pure $ parseWif komodo wif

  withConsensusNode consensusConfig $
    \node -> do
      let notariser = EthNotariser bitcoinConf node gethConfig gateway sk
      runZeno notariser ethNotariser






ethNotariser :: Zeno EthNotariser ()
ethNotariser = do
  KomodoIdent{..} <- asks has
  (EthIdent _ ethAddr) <- asks has
  logInfo $ "My KMD address: " ++ show kmdAddress
  logInfo $ "My ETH address: " ++ show ethAddr

  forkMonitorUTXOs kmdInputAmount 5 50

  runForever do

    nc@NotariserConfig{..} <- getNotariserConfig "KMDETH"
    asks has >>= checkConfig nc
    
    getLastNotarisationOnEth nc >>= 
      \case
        Nothing -> do
          logDebug "No prior notarisations found"
          height <- getKmdProposeHeight 10
          notariseToETH nc height

        Just (lastHeight, _, _, _) -> do
          logDebug $ "Found prior notarisation at height %i" % lastHeight
          -- Check if backnotarised to KMD

          getLastNotarisation "ETHTEST" >>=
            \case
              Just (Notarisation _ _ nor@NOR{..}) | blockNumber == lastHeight -> do
                let _ = nor :: NotarisationData Sha3
                logDebug "Found backnotarisation, proceed with next notarisation"
                newHeight <- getKmdProposeHeight 10
                if newHeight > lastHeight
                   then notariseToETH nc newHeight
                   else do
                     logDebug "Not enough new blocks, sleeping 60 seconds"
                     threadDelay $ 60 * 1000000

              _ -> do
                logDebug "Backnotarisation not found, proceed to backnotarise"
                notariseToKMD nc lastHeight

  where
    getNotariserConfig configName = do
      gateway <- asks getEthGateway
      (threshold, members) <- ethCallABI gateway "getMembers()" ()
      JsonInABI nc <- ethCallABI gateway "getConfig(string)" (configName :: Text)
      pure $ nc { members, threshold }

    checkConfig NotariserConfig{..} (EthIdent _ addr) = do
      when (majorityThreshold (length members) < kmdNotarySigs) $ do
        logError "Majority threshold is less than required notary sigs"
        impureThrow ConfigException 
      when (not $ elem addr members) $ do
        logError "I am not in the members list"
        impureThrow ConfigException

    runForever act = forever $ act `catches` handlers
      where
        handlers =
          [ Handler $ \e -> recover logInfo 5 (e :: ConsensusException)
          , Handler $ \e -> recover logWarn 60 (fmtHttpException e)
          , Handler $ \e -> recover logWarn 60 (e :: RPCException)
          , Handler $ \e -> recover logError 600 (e :: ConfigException)
          ]
        recover f d e = do
          f $ show e
          liftIO $ threadDelay $ d * 1000000
        fmtHttpException (HttpExceptionRequest _ e) = e




-- TODO: need error handling here with strategies for configuration errors, member mischief etc.
notariseToETH :: NotariserConfig -> Word32 -> Zeno EthNotariser ()
notariseToETH NotariserConfig{..} height32 = do

  let height = fromIntegral height32
  logDebug $ "Notarising from block %i" % height

  ident <- asks has
  gateway <- asks getEthGateway
  let cparams = ConsensusParams members ident consensusTimeout
  r <- ask
  let run = liftIO . runZeno r


  -- we already have all the data for the call to set the new block height
  -- in our ethereum contract. so create the call.

  blockHash <- bytes . unHex <$> queryBitcoin "getblockhash" [height]
  let notariseCallData = abi "notarise(uint256,bytes32,bytes)"
                             (height, blockHash :: Bytes 32, "" :: ByteString)
      proxyParams = (notarisationsContract, height, notariseCallData)
      sighash = ethMakeProxySigMessage proxyParams

  -- Ok now we have all the parameters together, we need to collect sigs and get the tx

  tx <- runConsensus cparams proxyParams $ do
    {- The trick is, that during this whole block inside runConsensus,
       each step will stay open until the end so that lagging nodes can
       join in late. -}

    run $ logDebug "Step 1: Collect sigs"
    sigBallots <- stepWithTopic sighash (collectThreshold threshold) ()

    run $ logDebug "Step 2: Get proposed transaction"
    let proxyCallData = ethMakeProxyCallData proxyParams (bSig <$> unInventory sigBallots)
    txProposed <- propose $ run $ ethMakeTransaction gateway proxyCallData
    -- TODO: verifications on proposed tx

    run $ logDebug "Step 3: Confirm proposal"
    _ <- step collectMajority ()
    pure txProposed

  logDebug "Step 4: Submit transaction"
  receipt <- postTransactionSync tx
  logDebug $ "posted transaction: " ++ show receipt
  pure ()


getLastNotarisationOnEth :: Integral i => NotariserConfig
                         -> Zeno EthNotariser (Maybe (i, Bytes 32, Integer, ByteString))
getLastNotarisationOnEth NotariserConfig{..} = do
  r <- ethCallABI notarisationsContract "getLastNotarisation()" ()
  pure $
    case r of
      (0::Integer, _, _, _) -> Nothing
      (h, hash, ethHeight, extra) -> Just (fromIntegral h, hash, ethHeight, extra)
