import Foundation
import CryptoSwift
import P256K

/// A BIP-39 seed phrase (12 or 24 words) and its derivation to the
/// Ethereum custody key at m/44'/60'/0'/0/0 — the path Warpcast and
/// other Farcaster wallets use for the custody address. A user coming
/// from Warpcast has a phrase, not a raw private key, so this is the
/// way in for a legacy Farcaster account: paste the phrase, the app
/// derives the custody key, and the existing recovery-key sign-in
/// (`bringYourFIDWithCustody`) takes it from there.
///
/// Test vector (public, no funds): the phrase
/// "abandon abandon abandon abandon abandon abandon abandon abandon
/// abandon abandon abandon about" derives the custody key
/// 1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727
/// and the address 0x9858effd232b4033e47d90003d41ec34ecaeda94.
/// Verified against a Python reference implementation (hashlib +
/// pure-Python secp256k1 + Keccak) before this file was written.
enum SeedPhrase {
    enum PhraseError: Error, LocalizedError {
        case wrongWordCount(Int)
        case unknownWord(String)
        case badChecksum
        case invalidKey

        var errorDescription: String? {
            switch self {
            case .wrongWordCount(let n):
                return "A seed phrase is 12 or 24 words — this one has \(n)."
            case .unknownWord(let word):
                return "\u{201c}\(word)\u{201d} is not a valid seed word. Check the spelling."
            case .badChecksum:
                return "That phrase does not check out — a word may be mistyped or out of order."
            case .invalidKey:
                return "Could not derive a key from that phrase."
            }
        }
    }

    /// The words, lowercased and split on whitespace, or an error.
    /// Accepts 12 or 24 words only (the lengths Warpcast uses).
    static func words(from phrase: String) throws -> [String] {
        let words = phrase
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count == 12 || words.count == 24 else {
            throw PhraseError.wrongWordCount(words.count)
        }
        for word in words where wordlistIndex[word] == nil {
            throw PhraseError.unknownWord(word)
        }
        return words
    }

    /// Validate the checksum: the last word carries the first bits
    /// of SHA-256 of the entropy, so a mistyped word is caught here
    /// instead of deriving a key for the wrong account.
    static func validate(_ words: [String]) throws {
        let indices = words.map { wordlistIndex[$0]! }
        // 11 bits per word, most-significant first.
        var bits: [Bool] = []
        bits.reserveCapacity(indices.count * 11)
        for index in indices {
            for shift in (0..<11).reversed() {
                bits.append((index >> shift) & 1 == 1)
            }
        }
        let entropyBits = words.count == 12 ? 128 : 256
        let checksumBits = bits.count - entropyBits
        var entropy = Data()
        for i in 0..<(entropyBits / 8) {
            var byte: UInt8 = 0
            for j in 0..<8 {
                if bits[i * 8 + j] { byte |= 1 << (7 - j) }
            }
            entropy.append(byte)
        }
        let hash = SHA2(variant: .sha256).calculate(for: [UInt8](entropy))
        for i in 0..<checksumBits {
            let expected = (hash[i / 8] >> (7 - (i % 8))) & 1 == 1
            if bits[entropyBits + i] != expected {
                throw PhraseError.badChecksum
            }
        }
    }

    /// The custody private key (32 bytes) for a seed phrase, as a
    /// 64-character hex string. Validates the phrase first, then
    /// derives the BIP-39 seed and the BIP-32 key at
    /// m/44'/60'/0'/0/0. The empty passphrase is Warpcast's.
    static func custodyPrivateKeyHex(for phrase: String) throws -> String {
        let words = try words(from: phrase)
        try validate(words)
        let seed = try mnemonicSeed(words: words)
        let key = try derivePath(seed: seed)
        return key.hexString
    }

    // MARK: - BIP-39 seed

    /// PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic" + passphrase
    /// (empty here), 64 bytes out.
    private static func mnemonicSeed(words: [String]) throws -> Data {
        let password = [UInt8](words.joined(separator: " ").utf8)
        let salt = [UInt8]("mnemonic".utf8)
        let pbkdf2 = try PKCS5.PBKDF2(password: password, salt: salt, iterations: 2048, keyLength: 64, variant: .sha512)
        return Data(try pbkdf2.calculate())
    }

    // MARK: - BIP-32 derivation at m/44'/60'/0'/0/0

    /// Derive the key at m/44'/60'/0'/0/0 from a 64-byte seed.
    /// The first three levels are hardened (index | 0x80000000), the
    /// last two are normal and need the parent's compressed public key.
    private static func derivePath(seed: Data) throws -> Data {
        // Master: HMAC-SHA512(key "Bitcoin seed", seed).
        let master = try hmacSHA512(key: Data("Bitcoin seed".utf8), message: seed)
        var priv = master.prefix(32)
        var chain = master.suffix(32)
        let path: [(index: UInt32, hardened: Bool)] = [
            (44, true), (60, true), (0, true), (0, false), (0, false),
        ]
        for step in path {
            let (childPriv, childChain) = try deriveChild(
                parentPriv: priv, parentChain: chain,
                index: step.index, hardened: step.hardened
            )
            priv = childPriv
            chain = childChain
        }
        return priv
    }

    private static func deriveChild(
        parentPriv: Data, parentChain: Data,
        index: UInt32, hardened: Bool
    ) throws -> (priv: Data, chain: Data) {
        var data = Data()
        if hardened {
            data.append(0x00)
            data.append(parentPriv)
            data.append(contentsOf: withUnsafeBytes(of: (index | 0x80000000).bigEndian) { Array($0) })
        } else {
            data.append(try compressedPublicKey(privateKey: parentPriv))
            data.append(contentsOf: withUnsafeBytes(of: index.bigEndian) { Array($0) })
        }
        let out = try hmacSHA512(key: parentChain, message: data)
        let tweak = out.prefix(32)
        let childChain = out.suffix(32)
        guard let childPriv = addModCurveOrder(tweak, parentPriv) else {
            throw PhraseError.invalidKey
        }
        return (childPriv, childChain)
    }

    /// The compressed public key (33 bytes, 0x02/0x03 prefix + x)
    /// for a private key, via P256K. The prefix is 0x02 when y is
    /// even, 0x03 when y is odd.
    private static func compressedPublicKey(privateKey: Data) throws -> Data {
        let pub = try CustodyKeys.publicKeyUncompressed(privateKey: privateKey)
        guard pub.count == 65, pub.first == 0x04 else {
            throw PhraseError.invalidKey
        }
        let y = pub[33..<65]
        let prefix: UInt8 = (y.last! & 1) == 0 ? 0x02 : 0x03
        return Data([prefix]) + pub[1..<33]
    }

    // MARK: - Primitives

    private static func hmacSHA512(key: Data, message: Data) throws -> Data {
        let hmac = HMAC(key: [UInt8](key), variant: .sha512)
        return Data(try hmac.authenticate([UInt8](message)))
    }

    /// (a + b) mod n for 32-byte big-endian scalars, n the secp256k1
    /// curve order. Returns nil when the result is zero (an invalid
    /// key). a and b are both below n, so a + b is below 2n and one
    /// conditional subtraction is enough; the carry case folds in
    /// 2^256 mod n, which is 2^256 - n.
    private static func addModCurveOrder(_ a: Data, _ b: Data) -> Data? {
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        let (sum, carry) = add32(aBytes, bBytes)
        let result: [UInt8]
        if carry {
            // a + b >= 2^256, so (a + b) mod n = sumLow + (2^256 - n).
            // That is below n already (a + b < 2n), so no further cut.
            let (reduced, _) = add32(sum, curveOrderComplement)
            result = reduced
        } else if compare32(sum, curveOrderBytes) >= 0 {
            result = subtract32(sum, curveOrderBytes)
        } else {
            result = sum
        }
        guard result.contains(where: { $0 != 0 }) else { return nil }
        return Data(result)
    }

    /// 2^256 - n, the value that folds a carry back into range.
    private static let curveOrderComplement: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x45, 0x51, 0x23, 0x19, 0x50, 0xB7, 0x5F, 0xC4,
        0x40, 0x2D, 0xA1, 0x73, 0x2F, 0xC9, 0xBE, 0xBF,
    ]

    private static let curveOrderBytes: [UInt8] = [UInt8](Ethereum.curveOrder)

    /// 32-byte big-endian addition. Returns the low 32 bytes and
    /// whether it carried out of the top.
    private static func add32(_ a: [UInt8], _ b: [UInt8]) -> (sum: [UInt8], carry: Bool) {
        var out = [UInt8](repeating: 0, count: 32)
        var carry = 0
        for i in (0..<32).reversed() {
            let s = Int(a[i]) + Int(b[i]) + carry
            out[i] = UInt8(s & 0xFF)
            carry = s >> 8
        }
        return (out, carry != 0)
    }

    /// Lexicographic compare of equal-length big-endian integers.
    private static func compare32(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for i in 0..<32 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        }
        return 0
    }

    /// a - b for 32-byte big-endian, assuming a >= b.
    private static func subtract32(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in (0..<32).reversed() {
            let d = Int(a[i]) - Int(b[i]) - borrow
            if d < 0 {
                out[i] = UInt8(d + 256)
                borrow = 1
            } else {
                out[i] = UInt8(d)
                borrow = 0
            }
        }
        return out
    }

    // MARK: - Wordlist

    /// The BIP-39 English wordlist (2048 words), from
    /// bitcoin/bips bip-0039/english.txt. A seed phrase is 12 or 24 of
    /// these words, in order; the last word carries a checksum, so a
    /// mistyped word is caught before anything is derived.
    private static let wordlistString = """
    abandon ability able about above absent absorb abstract absurd abuse
    access accident account accuse achieve acid acoustic acquire across act
    action actor actress actual adapt add addict address adjust admit
    adult advance advice aerobic affair afford afraid again age agent
    agree ahead aim air airport aisle alarm album alcohol alert
    alien all alley allow almost alone alpha already also alter
    always amateur amazing among amount amused analyst anchor ancient anger
    angle angry animal ankle announce annual another answer antenna antique
    anxiety any apart apology appear apple approve april arch arctic
    area arena argue arm armed armor army around arrange arrest
    arrive arrow art artefact artist artwork ask aspect assault asset
    assist assume asthma athlete atom attack attend attitude attract auction
    audit august aunt author auto autumn average avocado avoid awake
    aware away awesome awful awkward axis baby bachelor bacon badge
    bag balance balcony ball bamboo banana banner bar barely bargain
    barrel base basic basket battle beach bean beauty because become
    beef before begin behave behind believe below belt bench benefit
    best betray better between beyond bicycle bid bike bind biology
    bird birth bitter black blade blame blanket blast bleak bless
    blind blood blossom blouse blue blur blush board boat body
    boil bomb bone bonus book boost border boring borrow boss
    bottom bounce box boy bracket brain brand brass brave bread
    breeze brick bridge brief bright bring brisk broccoli broken bronze
    broom brother brown brush bubble buddy budget buffalo build bulb
    bulk bullet bundle bunker burden burger burst bus business busy
    butter buyer buzz cabbage cabin cable cactus cage cake call
    calm camera camp can canal cancel candy cannon canoe canvas
    canyon capable capital captain car carbon card cargo carpet carry
    cart case cash casino castle casual cat catalog catch category
    cattle caught cause caution cave ceiling celery cement census century
    cereal certain chair chalk champion change chaos chapter charge chase
    chat cheap check cheese chef cherry chest chicken chief child
    chimney choice choose chronic chuckle chunk churn cigar cinnamon circle
    citizen city civil claim clap clarify claw clay clean clerk
    clever click client cliff climb clinic clip clock clog close
    cloth cloud clown club clump cluster clutch coach coast coconut
    code coffee coil coin collect color column combine come comfort
    comic common company concert conduct confirm congress connect consider control
    convince cook cool copper copy coral core corn correct cost
    cotton couch country couple course cousin cover coyote crack cradle
    craft cram crane crash crater crawl crazy cream credit creek
    crew cricket crime crisp critic crop cross crouch crowd crucial
    cruel cruise crumble crunch crush cry crystal cube culture cup
    cupboard curious current curtain curve cushion custom cute cycle dad
    damage damp dance danger daring dash daughter dawn day deal
    debate debris decade december decide decline decorate decrease deer defense
    define defy degree delay deliver demand demise denial dentist deny
    depart depend deposit depth deputy derive describe desert design desk
    despair destroy detail detect develop device devote diagram dial diamond
    diary dice diesel diet differ digital dignity dilemma dinner dinosaur
    direct dirt disagree discover disease dish dismiss disorder display distance
    divert divide divorce dizzy doctor document dog doll dolphin domain
    donate donkey donor door dose double dove draft dragon drama
    drastic draw dream dress drift drill drink drip drive drop
    drum dry duck dumb dune during dust dutch duty dwarf
    dynamic eager eagle early earn earth easily east easy echo
    ecology economy edge edit educate effort egg eight either elbow
    elder electric elegant element elephant elevator elite else embark embody
    embrace emerge emotion employ empower empty enable enact end endless
    endorse enemy energy enforce engage engine enhance enjoy enlist enough
    enrich enroll ensure enter entire entry envelope episode equal equip
    era erase erode erosion error erupt escape essay essence estate
    eternal ethics evidence evil evoke evolve exact example excess exchange
    excite exclude excuse execute exercise exhaust exhibit exile exist exit
    exotic expand expect expire explain expose express extend extra eye
    eyebrow fabric face faculty fade faint faith fall false fame
    family famous fan fancy fantasy farm fashion fat fatal father
    fatigue fault favorite feature february federal fee feed feel female
    fence festival fetch fever few fiber fiction field figure file
    film filter final find fine finger finish fire firm first
    fiscal fish fit fitness fix flag flame flash flat flavor
    flee flight flip float flock floor flower fluid flush fly
    foam focus fog foil fold follow food foot force forest
    forget fork fortune forum forward fossil foster found fox fragile
    frame frequent fresh friend fringe frog front frost frown frozen
    fruit fuel fun funny furnace fury future gadget gain galaxy
    gallery game gap garage garbage garden garlic garment gas gasp
    gate gather gauge gaze general genius genre gentle genuine gesture
    ghost giant gift giggle ginger giraffe girl give glad glance
    glare glass glide glimpse globe gloom glory glove glow glue
    goat goddess gold good goose gorilla gospel gossip govern gown
    grab grace grain grant grape grass gravity great green grid
    grief grit grocery group grow grunt guard guess guide guilt
    guitar gun gym habit hair half hammer hamster hand happy
    harbor hard harsh harvest hat have hawk hazard head health
    heart heavy hedgehog height hello helmet help hen hero hidden
    high hill hint hip hire history hobby hockey hold hole
    holiday hollow home honey hood hope horn horror horse hospital
    host hotel hour hover hub huge human humble humor hundred
    hungry hunt hurdle hurry hurt husband hybrid ice icon idea
    identify idle ignore ill illegal illness image imitate immense immune
    impact impose improve impulse inch include income increase index indicate
    indoor industry infant inflict inform inhale inherit initial inject injury
    inmate inner innocent input inquiry insane insect inside inspire install
    intact interest into invest invite involve iron island isolate issue
    item ivory jacket jaguar jar jazz jealous jeans jelly jewel
    job join joke journey joy judge juice jump jungle junior
    junk just kangaroo keen keep ketchup key kick kid kidney
    kind kingdom kiss kit kitchen kite kitten kiwi knee knife
    knock know lab label labor ladder lady lake lamp language
    laptop large later latin laugh laundry lava law lawn lawsuit
    layer lazy leader leaf learn leave lecture left leg legal
    legend leisure lemon lend length lens leopard lesson letter level
    liar liberty library license life lift light like limb limit
    link lion liquid list little live lizard load loan lobster
    local lock logic lonely long loop lottery loud lounge love
    loyal lucky luggage lumber lunar lunch luxury lyrics machine mad
    magic magnet maid mail main major make mammal man manage
    mandate mango mansion manual maple marble march margin marine market
    marriage mask mass master match material math matrix matter maximum
    maze meadow mean measure meat mechanic medal media melody melt
    member memory mention menu mercy merge merit merry mesh message
    metal method middle midnight milk million mimic mind minimum minor
    minute miracle mirror misery miss mistake mix mixed mixture mobile
    model modify mom moment monitor monkey monster month moon moral
    more morning mosquito mother motion motor mountain mouse move movie
    much muffin mule multiply muscle museum mushroom music must mutual
    myself mystery myth naive name napkin narrow nasty nation nature
    near neck need negative neglect neither nephew nerve nest net
    network neutral never news next nice night noble noise nominee
    noodle normal north nose notable note nothing notice novel now
    nuclear number nurse nut oak obey object oblige obscure observe
    obtain obvious occur ocean october odor off offer office often
    oil okay old olive olympic omit once one onion online
    only open opera opinion oppose option orange orbit orchard order
    ordinary organ orient original orphan ostrich other outdoor outer output
    outside oval oven over own owner oxygen oyster ozone pact
    paddle page pair palace palm panda panel panic panther paper
    parade parent park parrot party pass patch path patient patrol
    pattern pause pave payment peace peanut pear peasant pelican pen
    penalty pencil people pepper perfect permit person pet phone photo
    phrase physical piano picnic picture piece pig pigeon pill pilot
    pink pioneer pipe pistol pitch pizza place planet plastic plate
    play please pledge pluck plug plunge poem poet point polar
    pole police pond pony pool popular portion position possible post
    potato pottery poverty powder power practice praise predict prefer prepare
    present pretty prevent price pride primary print priority prison private
    prize problem process produce profit program project promote proof property
    prosper protect proud provide public pudding pull pulp pulse pumpkin
    punch pupil puppy purchase purity purpose purse push put puzzle
    pyramid quality quantum quarter question quick quit quiz quote rabbit
    raccoon race rack radar radio rail rain raise rally ramp
    ranch random range rapid rare rate rather raven raw razor
    ready real reason rebel rebuild recall receive recipe record recycle
    reduce reflect reform refuse region regret regular reject relax release
    relief rely remain remember remind remove render renew rent reopen
    repair repeat replace report require rescue resemble resist resource response
    result retire retreat return reunion reveal review reward rhythm rib
    ribbon rice rich ride ridge rifle right rigid ring riot
    ripple risk ritual rival river road roast robot robust rocket
    romance roof rookie room rose rotate rough round route royal
    rubber rude rug rule run runway rural sad saddle sadness
    safe sail salad salmon salon salt salute same sample sand
    satisfy satoshi sauce sausage save say scale scan scare scatter
    scene scheme school science scissors scorpion scout scrap screen script
    scrub sea search season seat second secret section security seed
    seek segment select sell seminar senior sense sentence series service
    session settle setup seven shadow shaft shallow share shed shell
    sheriff shield shift shine ship shiver shock shoe shoot shop
    short shoulder shove shrimp shrug shuffle shy sibling sick side
    siege sight sign silent silk silly silver similar simple since
    sing siren sister situate six size skate sketch ski skill
    skin skirt skull slab slam sleep slender slice slide slight
    slim slogan slot slow slush small smart smile smoke smooth
    snack snake snap sniff snow soap soccer social sock soda
    soft solar soldier solid solution solve someone song soon sorry
    sort soul sound soup source south space spare spatial spawn
    speak special speed spell spend sphere spice spider spike spin
    spirit split spoil sponsor spoon sport spot spray spread spring
    spy square squeeze squirrel stable stadium staff stage stairs stamp
    stand start state stay steak steel stem step stereo stick
    still sting stock stomach stone stool story stove strategy street
    strike strong struggle student stuff stumble style subject submit subway
    success such sudden suffer sugar suggest suit summer sun sunny
    sunset super supply supreme sure surface surge surprise surround survey
    suspect sustain swallow swamp swap swarm swear sweet swift swim
    swing switch sword symbol symptom syrup system table tackle tag
    tail talent talk tank tape target task taste tattoo taxi
    teach team tell ten tenant tennis tent term test text
    thank that theme then theory there they thing this thought
    three thrive throw thumb thunder ticket tide tiger tilt timber
    time tiny tip tired tissue title toast tobacco today toddler
    toe together toilet token tomato tomorrow tone tongue tonight tool
    tooth top topic topple torch tornado tortoise toss total tourist
    toward tower town toy track trade traffic tragic train transfer
    trap trash travel tray treat tree trend trial tribe trick
    trigger trim trip trophy trouble truck true truly trumpet trust
    truth try tube tuition tumble tuna tunnel turkey turn turtle
    twelve twenty twice twin twist two type typical ugly umbrella
    unable unaware uncle uncover under undo unfair unfold unhappy uniform
    unique unit universe unknown unlock until unusual unveil update upgrade
    uphold upon upper upset urban urge usage use used useful
    useless usual utility vacant vacuum vague valid valley valve van
    vanish vapor various vast vault vehicle velvet vendor venture venue
    verb verify version very vessel veteran viable vibrant vicious victory
    video view village vintage violin virtual virus visa visit visual
    vital vivid vocal voice void volcano volume vote voyage wage
    wagon wait walk wall walnut want warfare warm warrior wash
    wasp waste water wave way wealth weapon wear weasel weather
    web wedding weekend weird welcome west wet whale what wheat
    wheel when where whip whisper wide width wife wild will
    win window wine wing wink winner winter wire wisdom wise
    wish witness wolf woman wonder wood wool word work world
    worry worth wrap wreck wrestle wrist write wrong yard year
    yellow you young youth zebra zero zone zoo
"""

    /// Word to its 11-bit index in the wordlist.
    private static let wordlistIndex: [String: Int] = {
        var dict: [String: Int] = [:]
        dict.reserveCapacity(2048)
        for (i, word) in wordlistString.split(whereSeparator: { $0.isWhitespace }).enumerated() {
            dict[String(word)] = i
        }
        return dict
    }()
}
