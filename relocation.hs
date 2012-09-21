{-# LANGUAGE 
      OverloadedStrings, RecordWildCards, ViewPatterns
    , TupleSections #-}
module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.RWS
import Data.Monoid ()
import Control.Arrow
import Data.Function
import Data.List
import Data.Maybe
import Text.Printf
import qualified Data.IntMap as Map
import qualified Data.Array as Array
import Numeric
import Debug.Trace
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString as BB
import qualified Data.Attoparsec.Char8 as PS
import Disassemble

main :: IO ()
main = do
    list <- read <$> readFile "findRAMList.txt"
    smwDisC <- smwDisCFile
    rom <- romFile
    let (s1, s2) = findAndShowCode list smwDisC rom
    BS.writeFile "relocationPatch.asm" s1
    BS.writeFile "relocationHijack.asm" s2
    putStrLn "OK"
--    absAddressChangeOnly

absAddressChangeOnly :: IO ()
absAddressChangeOnly = do
    list <- read <$> readFile "findRAMListAACO.txt"
    smwDisC <- smwDisCFile
    rom <- romFile
    let s = aacoAndShowCode list smwDisC rom
    BS.writeFile "relocationAACO.asm" s
    putStrLn "AACO: OK"

aacoAndShowCode :: [(Int, String)] -> BS.ByteString -> Bytes -> BS.ByteString
aacoAndShowCode m smwDisC rom =
    let (r, s) = initalHJ smwDisC rom (Map.fromList$ map (second BS.pack) m) in
    let (c, s') = execHJ (mapM_ findAndAACO (map fst m)) r s in
    let g = runReader (genCodeAll =<< codeListGen c) (initalReadState2 r s') in
    let (q, _) = showCodeBlocks g in
    q

findAndShowCode :: [(Int, String)] -> BS.ByteString -> Bytes -> (BS.ByteString, BS.ByteString)
findAndShowCode m smwDisC rom =
    let (r, s) = initalHJ smwDisC rom (Map.fromList$ map (second BS.pack) m) in
    let (c, s') = execHJ (mapM_ findAndLongAddressing (map fst m)) r s in
    let g = runReader (genCodeAll =<< codeListGen c) (initalReadState2 r s') in
    showCodeBlocks g

showCodeBlocks :: [CodeBlock] -> (BS.ByteString, BS.ByteString)
showCodeBlocks = join (***) BS.unlines. unzip. map showCodeBlock

showCodeBlock :: CodeBlock -> (BS.ByteString, BS.ByteString)
showCodeBlock (a, e, xs) = (codeBlockHijackCode a,)$
    BS.unlines$
    codeBlockIntroCode a
    : (map showCodeLine xs
    ++ [codeBlockEndingCode e])

hijackCodeLabel :: Address -> BS.ByteString
hijackCodeLabel a = BS.pack$ printf "HIJACK_%06X" (enumToSNESAddress a)

codeBlockHijackCode, codeBlockIntroCode, codeBlockEndingCode :: Address -> BS.ByteString

codeBlockHijackCode a = BS.concat
    [ BS.pack$ printf "org $%06X\n" (enumToSNESAddress a)
    , "\tJML ", hijackCodeLabel a
    ]

codeBlockIntroCode a = hijackCodeLabel a `BS.append` ":"

codeBlockEndingCode a = BS.pack$ printf "\tJML $%06X" (enumToSNESAddress a)

showCodeLine :: CodeLine -> BS.ByteString
showCodeLine (CodeLine {..}) = BS.concat$ [ clLabel, ":\t"] ++ code
    where code = tail$ concatMap (\x-> [" : ", showPatchCode x]) clCode

initalReadState2 :: ReadState -> AddressStateMap -> ReadState
initalReadState2 r s = r { brokenMap = s }

-- gen code

genCodeAll :: [CodeListGen] -> HJRead [CodeBlock]
genCodeAll = mapM genCode

genCode :: CodeListGen -> HJRead CodeBlock
genCode xs = (,,) a0 <$> endAddr <*>
    mapM (\(a, x)-> CodeLine <$> getCodeLabel a <*> genCodeLine a x) xs
    where
        a0 = fst$ head xs
        endAddr = let (a, _) = last xs in
            do
                AddressInfo { aiBytes = (BB.length -> z)} <- getAddressInfo a
                return (a + z)

genCodeLine :: Address -> CodeGenType -> HJRead [PatchCode]
genCodeLine a x = do
    info <- getAddressInfo a
    let asm = aiAssembly info
    let asm' = fromJust$ asm
    let db = [CodeDB$ aiBytes info]
    case x of
        GenBrokenCode ->
            maybe (return db) (genBrokenCode a)$ asm
        GenNewCode LongAddressing ->
            longAddressingCode asm'
        GenNewCode BrokenJump ->
            genBrokenCode a asm'
        GenNewCode BrokenExecutePtr ->
            genBrokenExecutePtr a
        GenNewCode AACO ->
            genAACO asm'

genAACO :: Assembly -> HJRead [PatchCode]
genAACO (asm@Assembly {..}) = do
    macro <- getRAMMacroName (fromJust$ getOperandInt operand)
    return$ assemblyToAACO asm macro

longAddressingCode :: Assembly -> HJRead [PatchCode]
longAddressingCode (asm@Assembly {..}) = do
    macro <- getRAMMacroName (fromJust$ getOperandInt operand)
    return$ assemblyToLongAddressing asm macro

genBrokenExecutePtr :: Address -> HJRead [PatchCode]
genBrokenExecutePtr a = do
    (ExecutePtr {..}) <- (Map.! a). executePtr <$> ask
    (jsl:) <$> mapM (f epIsLong) epTable
    where
        jsl = CodeAssembly. assemblyToAssembly'. fromJust$
            disassembleCode (BB.pack [0x22, 0xFA, 0x86, 0x00])
        f isLong x = do
            b <- (Map.! x). brokenMap <$> ask
            opr <- if b
                then getCodeLabel x
                else return (BS.pack$ printf "$%06X" addr)
            return$ CodeRaw$
                "dl " `BS.append` opr
            where
                addr = enumToSNESAddress x

genBrokenCode :: Address -> Assembly -> HJRead [PatchCode]
genBrokenCode a asm
    | isJust special = return$ fromJust special
    | isJust rts = return$ map CodeAssembly$ fromJust rts
    | isJust jumpAddr = do
        j <- getAddressOrigin jumpAddr''
        b <- (Map.! j). brokenMap <$> ask
        if b
        then do
            label <- getCodeLabel jumpAddr''
            return$ assemblyToLongJump asm (Right label) bank
        else return$ assemblyToLongJump asm (Left jumpAddr') bank
    | otherwise = return$ map CodeAssembly [assemblyToAssembly' asm]
    where
        a' = enumToSNESAddress a
        bank = a' `div` 0x10000
        special = map CodeAssembly <$> genSpecialCode a' asm
        jumpAddr'' = snesAddressToEnum jumpAddr'
        jumpAddr' = fromJust jumpAddr
        jumpAddr = getJumpAddress a' asm
        rts = genRTSCode bank asm

getCodeLabel :: Address -> HJRead BS.ByteString
getCodeLabel a = return$
    BS.pack$ printf "HJ_%06X" (enumToSNESAddress a)

type CodeBlock = (Address, Int, [CodeLine])

data CodeLine = CodeLine
    { clLabel :: BS.ByteString
    , clCode :: [PatchCode]
    }
    deriving (Show)

-- CodeListGen

codeListGen :: [CodeGen] -> HJRead [CodeListGen]
codeListGen xs = map (map fst). groupBy' g <$> mapM (\x->(x,)<$>f x) xs
    where
        f (a, _) = BB.length. aiBytes <$> getAddressInfo a
        g ((a, _), z) ((b, _), _) = a + z == b
        groupBy' _ [] = []
        groupBy' _ [x] = [[x]]
        groupBy' f (x:y:xs)
            | f x y = let (z:zs) = groupBy' f (y:xs) in (x:z):zs
            | otherwise = [x] : groupBy' f (y:xs)

type CodeListGen = [(Address, CodeGenType)]

-- CodeGen

execHJ :: HJ () -> ReadState -> AddressStateMap -> ([CodeGen], AddressStateMap)
execHJ a r s =
    let (t, s', w) = runRWS (a >> getGenBrokenCode) r s in
    (mergeCodeGen t (sortBy (compare`on`fst)$ newCodeCodeGen w), s')
    where
        mergeCodeGen xxs@((a, x):xs) yys@((b, y):ys) = case compare a b of
            EQ -> (b, y) : mergeCodeGen xs ys
            LT -> (a, x) : mergeCodeGen xs yys
            GT -> (b, y) : mergeCodeGen xxs ys
        mergeCodeGen xs ys = xs ++ ys

newCodeCodeGen :: [NewCode] -> [CodeGen]
newCodeCodeGen = map f
    where
        f (NewCode {..}) = (ncOriginalAddress, GenNewCode ncType)

getGenBrokenCode :: HJ [CodeGen]
getGenBrokenCode = map (second (const GenBrokenCode)). filter snd.
    Map.assocs <$> getAddressStateMap

type CodeGen = (Address, CodeGenType)
data CodeGenType =
      GenBrokenCode
    | GenNewCode NewCodeType
    deriving (Show)

-- ExecutePtr
createExecutePtrJumpRev :: ExecutePtrMap -> JumpRev
createExecutePtrJumpRev e =
    foldr (\(a, Right-> b)-> Map.alter (Just. maybe [b] (b:)) a) Map.empty.
    concatMap f$ Map.assocs e
    where
        f (a, ExecutePtr {..}) = map (\x-> (x, a)) epTable

type ExecutePtrRev = Map.IntMap [Address]
type ExecutePtrMap = Map.IntMap ExecutePtr

createExecutePtr :: AddressInfoMap -> ExecutePtrMap
createExecutePtr m = Map.fromList$ f$ Map.assocs m
    where
        f ((a,x):y:zs)
            | isJust e = (a, ExecutePtr e' (takeWhile g$ createTable e' bank (aiBytes$ snd y))) : f zs
            | otherwise = f (y:zs)
            where
                bank = enumToSNESAddress a `div` 0x10000
                e' = fromJust e
                e = isExecutePtrLong =<< aiAssembly x
        f _ = []
        g x = maybe False (\x-> isJust$ aiAssembly x)$ Map.lookup x m
        createTable isLong bank bs
            | BB.null bs = []
            | otherwise =
                let (t, us) = BB.splitAt size bs in
                if BB.length t < size then []
                else snesAddressToEnum (g t) : createTable isLong bank us
            where
                size = if isLong then 3 else 2
                g x = (if isLong then id else (bank*0x10000+))$
                    foldr (\x y-> y * 0x100 + x) 0. map fromIntegral$ BB.unpack x

data ExecutePtr = ExecutePtr
    { epIsLong :: Bool
    , epTable :: [Address]
    }
    deriving (Show)

-- BrokenJump

findAndBrokenJumpMany :: Address -> HJ ()
findAndBrokenJumpMany a =
    mapM_ findAndBrokenJumpMany. concat =<< mapM createRange =<< findAndBrokenJump a
    where
        createRange a = unique <$> mapM (liftRead. getAddressOrigin) [a..a+3]

findAndBrokenJump :: Address -> HJ [Address]
findAndBrokenJump a =
    filterMap id <$> (mapM createBrokenJump =<< liftRead (getAddressJumpRev a))

createBrokenJump :: JumpType -> HJ (Maybe Address)
createBrokenJump (either (,False) (,True)-> (a, f)) = do
    b <- getAddressBroken a
    if b
    then return Nothing
    else do
        breakJMLBytes a
        addNewCode c
        return (Just a)
    where
        c = NewCode
            { ncOriginalAddress = a
            , ncType = if f
                then BrokenExecutePtr
                else BrokenJump
            }

getAddressJumpRev :: Address -> HJRead [JumpType]
getAddressJumpRev a = fromMaybe []. Map.lookup a. jumpRev <$> ask

-- そのアドレスがどこから参照されているか？
-- AddressInfoMapとかの境界に切り捨てる
-- 間接ジャンプは無理だから手動で追加する？
createJumpRev :: AddressInfoMap -> AddressOrigin -> JumpRev
createJumpRev m o = foldr (\(a, Left-> b)-> Map.alter (Just. maybe [b] (b:)) a) Map.empty ts
    where
        ts = filterMap f$ Map.assocs m
        f (a, x) = do
            s <- aiAssembly x
            j' <- getJumpAddress (enumToSNESAddress a) s
            let j = snesAddressToEnum j'
            guard$ 0 <= j && j < size
            return$ (o Array.! j, a)
        size = lasta + BB.length lastb - 1
        (lasta, AddressInfo { aiBytes = lastb }) = Map.findMax m

type JumpRev = Map.IntMap [JumpType]
type JumpType = Either Address Address

findAndAACO :: Address -> HJ ()
findAndAACO x =
    mapM_ createAACO =<< findRAMAccess x

createAACO :: Address -> HJ ()
createAACO a = do
    addNewCode (NewCode a AACO)

findAndLongAddressing :: Address -> HJ ()
findAndLongAddressing x =
    mapM_ createLongAddressing =<< findRAMAccess x

findRAMAccess :: Int -> HJ [Address]
findRAMAccess x = map fst. filter f. Map.assocs <$> liftRead getAddressInfoMap
    where
        f (_, AddressInfo {aiAssembly = Just (Assembly {..})}) =
            isMemoryAccessAddressing addressingMode
            && getOperandInt operand == Just x
        f _ = False

createLongAddressing :: Address -> HJ ()
createLongAddressing a = do
    breakJMLBytes a
    mapM_ findAndBrokenJumpMany. unique =<<
        mapM (liftRead. getAddressOrigin) [a..a+3]
    addNewCode c
    where
        c = NewCode
            { ncOriginalAddress = a
            , ncType = LongAddressing
            }

breakJMLBytes :: Address -> HJ ()
breakJMLBytes a = breakBytes a 4

breakBytes :: Address -> Size -> HJ ()
breakBytes a size = mapM_ breakOriginAddress =<< liftRead (getAddressOrigins a size)

breakOriginAddress :: Address -> HJ ()
breakOriginAddress = modifyAddressState (const True)

getRAMMacroName :: Int -> HJRead BS.ByteString
getRAMMacroName a = (Map.! a). ramMacroName <$> ask

getAddressOrigin :: Address -> HJRead Address
getAddressOrigin a = (Array.! a). addressOrigin <$> ask

getAddressOrigins :: Address -> Size -> HJRead [Address]
getAddressOrigins a size = unique <$> mapM getAddressOrigin [a..a+size-1]

modifyAddressState :: (AddressState -> AddressState) -> Address -> HJ ()
modifyAddressState f a = modifyAddressStateMap$ Map.adjust f a

getAddressStateMap :: HJ AddressStateMap
getAddressStateMap = get

getAddressInfoMap :: HJRead AddressInfoMap
getAddressInfoMap = addressInfoMap <$> ask

getAddressInfo :: Address -> HJRead AddressInfo
getAddressInfo a = (Map.! a) <$> getAddressInfoMap

getAddressBroken :: Address -> HJ Bool
getAddressBroken a = (Map.! a) <$> getAddressStateMap

modifyAddressStateMap :: (AddressStateMap -> AddressStateMap) -> HJ ()
modifyAddressStateMap = modify

addNewCode :: NewCode -> HJ ()
addNewCode c = tell [c]

initalReadState :: BS.ByteString -> Bytes -> RAMMacroNameMap -> ReadState
initalReadState s r n = t
    where
        m = initalAddressInfoMap s r
        t = ReadState
            { addressOrigin = o
            , addressInfoMap = aim
            , jumpRev = createExecutePtrJumpRev e `Map.union` createJumpRev aim o
            , ramMacroName = n
            , executePtr = e
            , brokenMap = error "brokenMap"
            }
            where
                aim = initalAddressInfoMap s r
                o = createAddressOrigin m
                e = createExecutePtr aim

initalHJ :: BS.ByteString -> Bytes -> RAMMacroNameMap -> (ReadState, AddressStateMap)
initalHJ s r n = (m, Map.map (const False)$ addressInfoMap m)
    where
        m = initalReadState s r n

createAddressOrigin :: AddressInfoMap -> AddressOrigin
createAddressOrigin m = Array.array (0, fst (last ts)) ts
    where
        ts = concatMap f (Map.assocs m)
        f (a, AddressInfo { aiBytes = (BB.length -> l)}) =
            map (\a'-> (a', a)) [a..a+l-1]

initalAddressInfoMap :: BS.ByteString -> Bytes -> AddressInfoMap
initalAddressInfoMap s r = Map.fromList$ createAddressInfos s r

liftRead :: HJRead a -> HJ a
liftRead (ReaderT { runReaderT = f }) =
    RWST { runRWST = \r s-> f r >>= return. (, s, mzero) }

type Address = Int
type Size = Int

type AddressState = Bool

-- 新しいコードは、その他のhijack情報が必要なこともあるので、
-- ある程度だけ覚えておいて、コードは最後に生成する
-- BrokenJumpはBrokenなAddressに対してを検索してそこにBrokenJump+Brokenに…をやる感じで？
data NewCode = NewCode
    { ncOriginalAddress :: Int
    , ncType :: NewCodeType
    } deriving (Show)

data NewCodeType = LongAddressing | BrokenJump | BrokenExecutePtr | AACO
    deriving (Show)

type AddressStateMap = Map.IntMap AddressState
type AddressInfoMap = Map.IntMap AddressInfo
type AddressOrigin = Array.Array Int Int
type RAMMacroNameMap = Map.IntMap BS.ByteString

data ReadState = ReadState
    { addressOrigin :: AddressOrigin
    , addressInfoMap :: AddressInfoMap
    , jumpRev :: JumpRev
    , ramMacroName :: RAMMacroNameMap
    , executePtr :: ExecutePtrMap
    , brokenMap :: AddressStateMap
    } deriving (Show)

type HJ = RWS ReadState [NewCode] AddressStateMap
type HJRead = Reader ReadState

type Bytes = BB.ByteString

data AddressInfo = AddressInfo
    { aiBytes :: Bytes
    , aiAssembly :: Maybe Assembly  -- Nothingの場合、Dataである
    } deriving (Show)

createAddressInfos :: BS.ByteString -> Bytes -> [(Int, AddressInfo)]
createAddressInfos smwDisC rom =
    smwDisCAddressToAddressInfoWithROM
        (smwDisCAddressUnionData$ addressSMWDisC$ parseSMWDisCFile smwDisC)
        rom

smwDisCAddressUnionData :: [SMWDisCAddress] -> [SMWDisCAddress]
smwDisCAddressUnionData xs = f xs
    where
        f ((x@SMWDisCAddress {sdaIsData = True}):(y@SMWDisCAddress {sdaIsData = True}):zs) =
            f (SMWDisCAddress
                { sdaIsData = True
                , sdaAddress = sdaAddress x
                , sdaLength = sdaLength x + sdaLength y
                } : zs)
        f (x:xs) = x : f xs
        f x = x

smwDisCAddressToAddressInfoWithROM :: [SMWDisCAddress] -> Bytes -> [(Int, AddressInfo)]
smwDisCAddressToAddressInfoWithROM s x = f (BB.drop 0x200 x) s
    where
        f _ [] = []
        f x (SMWDisCAddress {..} : xs) = (sdaAddress, AddressInfo
            { aiBytes = t
            , aiAssembly = guard (not sdaIsData) >> disassembleCode t
            }) : f d xs
            where (t, d) = BB.splitAt sdaLength x

addressSMWDisC :: [SMWDisC] -> [SMWDisCAddress]
addressSMWDisC x = f 0 x
    where
        f _ [] = []
        f n (SMWDisC {..}:xs) =
            SMWDisCAddress
                { sdaIsData = fromMaybe False sdcIsData
                , sdaAddress = a
                , sdaLength = sdcLength
                } : f (a+sdcLength) xs
            where
                a = case sdcAddress of
                    Just (snesAddressToEnum-> x) -> if n == x
                        then x
                        else error$ printf "sdcAddress: %X /= %X" n x
                    Nothing -> n

type SNESAddress = Int

data SMWDisC = SMWDisC
    { sdcIsData :: Maybe Bool
    , sdcAddress :: Maybe SNESAddress
    , sdcLength :: Int
    } deriving (Show)

data SMWDisCAddress = SMWDisCAddress
    { sdaIsData :: Bool
    , sdaAddress :: Int
    , sdaLength :: Int
    } deriving (Show)

snesAddressToEnum :: SNESAddress -> Int
snesAddressToEnum x = x `div` 0x10000 * 0x8000 + x `mod` 0x8000

enumToSNESAddress :: Int -> SNESAddress
enumToSNESAddress x = x `div` 0x8000 * 0x10000 + 0x8000 + x `mod` 0x8000

smwDisCFile :: IO BS.ByteString
smwDisCFile = BS.readFile "SMWDisC.txt"

romFile :: IO BB.ByteString
romFile = BB.readFile "base.smc"

parseSMWDisCFile :: BS.ByteString -> [SMWDisC]
parseSMWDisCFile = parseSMWDisC. f (1 :: Int). BS.lines
    where
        -- 間違っている(邪魔な)行を取り除いたり、加工する
        f _ [] = []
        f n (x:xs)
            | n == 1852 || n == 1853
            || (13874 <= n && n <= 14469)
            || (22295 <= n && n <= 22319)
            || n == 23645
            || n == 106180
            = f (n+1) xs
            -- bytesを追加
            | n == 33938 = "Instr02A4E5:        9D 0B 17      STA.W $170B,x " : f (n+1) xs
            | n == 35687 = "ADDR_02B31C:        95 B6         STA RAM_SpriteSpeedX,X " : f (n+1) xs
            -- スペース！
            | n == 107250 = "CODE_0DAA0D: A9 00         LDA.B #$00 " : f (n+1) xs
            -- 抜けてる…
            | n == 112156 = "CODE_0DE000:  E8  INX " : f (n+1) xs
            | n == 113412 = BS.pack ("DATA_0DF001:  "++data_0DF001++
                "  db "++(intercalate ",". map('$':). words$ data_0DF001)) : f (n+1) xs
            | otherwise = x : f (n+1) xs
        -- 明らかにcodeな気がするけどめんどくさいのでデータ扱いで
        data_0DF001 = "A5 00 85 02 8A 49 01 AA 20 7D A9 C6 01 D0 CE 20 08 AA A9 6B D0 05 20 08 AA A9 6C 20 5B A9 C6 00 D0 F4 20 08 AA A9 6D 97 6B 60 A4 57 A5 59 29 0F 85 00 A5 59 4A 4A 4A 4A 85 01 20 B1 A6 A6 00 20 08 AA A9 0F 20 5B A9 CA 10 F5 4C 5B F0 A6 00 20 0D AA A9 EA 20 5B A9 CA 10 F5 20 BA A6 20 7D A9 C6 01 10 E9 60 A2 02 4C CE EC 59 A4 57 A5 59 29 0F 85 00 A5 59 4A 4A 4A 4A AA 20 08 AA BF 6B F0 0D 20 5B A9 C6 00 10 F2 60"

parseSMWDisC :: [BS.ByteString] -> [SMWDisC]
parseSMWDisC = filterMap (eitherToMaybe. PS.parseOnly parseSMWDisCLine)

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe (Left _) = Nothing
eitherToMaybe (Right x) = Just x

parseSMWDisCLine :: PS.Parser SMWDisC
parseSMWDisCLine = isData <|> isNotData <|> unknownAddress <|> unknownOnly <|> lengthOnly
    where
        isData = do
            PS.string "DATA_"
            a <- PS.hexadecimal
            PS.char ':'
            spaces
            SMWDisC (Just True) (Just a) <$> (bytesLength <|> dbdw)
        isNotData = do
            s <- PS.takeWhile (/= ' ') -- 先読み
            guard$ BS.length s >= 7   -- 汚い…
            let sa = BS.init$ BS.drop (BS.length s - 7) s
            a <- maybe (fail "aaa") return$ readMaybe readHex$ BS.unpack sa
            spaces
            l <- bytesLength
            spaces
            (\b-> SMWDisC b (Just a) l) <$> isdbdw
        isdbdw =
                (PS.char '.' >> return (Just True)) <|>
                (PS.satisfy PS.isAlpha_ascii >> return (Just False))
        unknownAddress = do
            PS.many1 (PS.satisfy (\c-> c /= ':' && c /= ' '))
            PS.char ':'
            unknownOnly
        dbdw = do
            PS.char '.'
            db <|> dw
            where
                db = PS.string "db" >> dbdws
                dw = PS.string "dw" >> (2*) <$> dbdws
                dbdws = PS.space >>
                    length <$> PS.sepBy (PS.many1 (PS.satisfy (\c-> c /= ' ' && c /= ','))) (PS.char ',')
        unknownOnly = do
            spaces
            uncurry (flip SMWDisC Nothing) <$> ((Just True,) <$> dbdw) <|> (do
                l <- bytesLength
                spaces
                (dat <|> code) <*> return l)
            where
                dat = PS.char '.' >> return (SMWDisC (Just True) Nothing)
                code = PS.satisfy PS.isAlpha_ascii >> return (SMWDisC (Just False) Nothing)
        lengthOnly = do
            spaces
            SMWDisC Nothing Nothing <$> (bytesLength <|> dbdw)
        bytes = PS.many1 (do
            x <- PS.hexadecimal :: PS.Parser Int
            PS.space
            return x)
        bytesLength = length <$> bytes
        spaces = PS.many1 PS.space

-- ユーティリティ
readMaybe :: ReadS a -> String -> Maybe a
readMaybe f x = case f x of
    [(y,"")] -> Just y
    _ -> Nothing

filterMap :: (a -> Maybe b) -> [a] -> [b]
filterMap f (x:xs) = case f x of
    Just y -> y : filterMap f xs
    Nothing -> filterMap f xs
filterMap _ [] = []

unique :: Eq a => [a] -> [a]
unique (x:y:zs)
    | x == y = unique (y:zs)
    | otherwise = x : unique (y:zs)
unique xs = xs

infixl 0 `traceSeq`
traceSeq s x = trace s () `seq` x
