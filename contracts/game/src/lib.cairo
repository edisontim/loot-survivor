mod game {
    mod constants;
    mod interfaces;
    mod renderer;
    mod encoding;
    mod RenderContract;
    mod snip12_controller_claim;
}
mod tests {
    mod test_game;
    mod mock_randomness;
    mod oz_constants;
    mod mocks {
        mod erc20_mocks;
        mod erc721_mocks;
    }
}

const SECONDS_IN_DAY: u64 = 86400;
const SECONDS_IN_MONTH: u64 = 2592000;

#[derive(Copy, Drop, PartialEq, Serde)]
enum FreeGameTokenType {
    GoldenToken,
    LaunchTournamentChampion,
}

#[generate_trait]
impl ImplFreeGameTokenType of IFreeGameTokenType {
    fn get_cooldown(self: FreeGameTokenType) -> u64 {
        match self {
            FreeGameTokenType::GoldenToken => SECONDS_IN_DAY,
            FreeGameTokenType::LaunchTournamentChampion => SECONDS_IN_MONTH,
        }
    }
}

use core::starknet::ContractAddress;

#[derive(Drop, Copy, Serde)]
struct LaunchTournamentCollections {
    collection_address: ContractAddress,
    games_per_token: u8,
}

#[starknet::contract]
mod Game {
    use alexandria_math::pow;
    use openzeppelin::token::erc721::erc721::ERC721Component::InternalTrait;
    use core::starknet::SyscallResultTrait;
    use core::num::traits::Bounded;
    use core::{
        array::{SpanTrait, ArrayTrait}, clone::Clone,
        starknet::{
            get_caller_address, ContractAddress, ContractAddressIntoFelt252, contract_address_const,
            get_block_timestamp, get_tx_info, info::BlockInfo, storage::{Map, Vec}
        },
    };
    use core::starknet::storage::StoragePointerReadAccess;
    use core::starknet::storage::MutableVecTrait;
    use core::starknet::storage::StoragePathEntry;

    use openzeppelin::token::erc20::interface::{
        IERC20Camel, IERC20Dispatcher, IERC20DispatcherTrait, IERC20CamelLibraryDispatcher
    };
    use openzeppelin::token::erc721::interface::{
        IERC721, IERC721Dispatcher, IERC721DispatcherTrait, IERC721LibraryDispatcher
    };
    use openzeppelin::token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::introspection::interface::{ISRC5Dispatcher, ISRC5DispatcherTrait};
    use openzeppelin::account::dual_account::{DualCaseAccount, DualCaseAccountABI};

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    use poseidon::poseidon_hash_span;

    use pragma_lib::abi::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};

    use super::{FreeGameTokenType, ImplFreeGameTokenType, LaunchTournamentCollections};
    use super::game::{
        interfaces::{
            IGame, IERC721Mixin, IBeasts, IBeastsDispatcher, IBeastsDispatcherTrait,
            IDelegateAccountDispatcher, IDelegateAccountDispatcherTrait
        },
        snip12_controller_claim::{Message, OffchainMessageHashImpl, SNIP12Metadata},
        constants::{
            messages, Rewards, REWARD_DISTRIBUTIONS_BP, COST_TO_PLAY, STARTER_BEAST_ATTACK_DAMAGE,
            MINIMUM_DAMAGE_FROM_BEASTS, MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID, KATANA_CHAIN_ID,
            MINIMUM_SCORE_FOR_PAYOUTS, MINIMUM_SCORE_FOR_DEATH_RANK, SECONDS_IN_DAY,
            TARGET_PRICE_USD_CENTS, VRF_COST_PER_GAME, VRF_MAX_CALLBACK_MAINNET,
            VRF_MAX_CALLBACK_TESTNET, PRAGMA_LORDS_KEY, PRAGMA_PUBLISH_DELAY, PRAGMA_NUM_WORDS,
            GAME_EXPIRY_DAYS, OBITUARY_EXPIRY_DAYS, MAX_U64,
            CONTROLLER_DELEGATE_ACCOUNT_INTERFACE_ID, DAO_CONTRACT_REWARD_ADVENTURER,
            PG_CONTRACT_REWARD_ADVENTURER
        },
        RenderContract::{
            IRenderContract, IRenderContractDispatcher, IRenderContractDispatcherTrait
        },
    };

    use loot::{loot::{ILoot, Loot, ImplLoot}, constants::{ItemId, SUFFIX_UNLOCK_GREATNESS}};
    use adventurer::{
        adventurer::{Adventurer, ImplAdventurer, IAdventurer, ItemLeveledUp, ItemSpecial},
        stats::{Stats, ImplStats}, item::{ImplItem, Item}, equipment::{Equipment, ImplEquipment},
        bag::{Bag, IBag, ImplBag}, adventurer_meta::{AdventurerMetadata, ImplAdventurerMetadata},
        constants::{
            discovery_constants::DiscoveryEnums::{ExploreResult, DiscoveryType},
            adventurer_constants::{
                POTION_HEALTH_AMOUNT, ITEM_XP_MULTIPLIER_BEASTS, ITEM_XP_MULTIPLIER_OBSTACLES,
                ITEM_MAX_GREATNESS, MAX_GREATNESS_STAT_BONUS, VITALITY_INSTANT_HEALTH_BONUS,
                BEAST_SPECIAL_NAME_LEVEL_UNLOCK, XP_FOR_DISCOVERIES, STARTING_GOLD, STARTING_HEALTH,
                BASE_POTION_PRICE, CHARISMA_ITEM_DISCOUNT, MINIMUM_DAMAGE_TO_BEASTS,
                MINIMUM_DAMAGE_FROM_OBSTACLES, MAX_STAT_UPGRADES_AVAILABLE, TWO_POW_32, TWO_POW_16
            }
        },
        leaderboard::{Score, Leaderboard},
    };

    use market::{
        market::{ImplMarket, LootWithPrice, ItemPurchase},
        constants::{NUMBER_OF_ITEMS_PER_LEVEL, TIER_PRICE},
    };
    use obstacles::obstacle::{ImplObstacle, IObstacle};
    use combat::{
        combat::{CombatSpec, SpecialPowers, ImplCombat},
        constants::{CombatSettings::STRENGTH_DAMAGE_BONUS, CombatEnums::{Slot, Tier, Type}}
    };
    use beasts::beast::{Beast, IBeast, ImplBeast};

    impl SRC5 = SRC5Component::SRC5Impl<ContractState>;
    impl ERC721 = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721Metadata = ERC721Component::ERC721MetadataImpl<ContractState>;
    impl ERC721CamelOnly = ERC721Component::ERC721CamelOnlyImpl<ContractState>;
    impl ERC721MetadataCamelOnly = ERC721Component::ERC721MetadataCamelOnlyImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        _adventurer: Map::<felt252, Adventurer>,
        _adventurer_client_provider: Map::<felt252, ContractAddress>,
        _adventurer_dropped_items: Vec<Item>,
        _adventurer_meta: Map::<felt252, AdventurerMetadata>,
        _adventurer_minter: Map::<felt252, ContractAddress>,
        _adventurer_name: Map::<felt252, felt252>,
        _adventurer_obituary: Map::<felt252, ByteArray>,
        _adventurer_renderer: Map::<felt252, ContractAddress>,
        _adventurer_vrf_allowance: Map::<felt252, u128>,
        _bag: Map::<felt252, Bag>,
        _beasts_dispatcher: IBeastsDispatcher,
        _cost_to_play: u128,
        _default_renderer: ContractAddress,
        _eth_dispatcher: IERC20Dispatcher,
        _free_vrf_promotion_duration_seconds: u64,
        _game_count: felt252,
        _genesis_timestamp: u64,
        _golden_token_dispatcher: IERC721Dispatcher,
        _golden_token_last_use: Map::<u32, u64>,
        _launch_tournament_champions_dispatcher: IERC721Dispatcher,
        _launch_tournament_claimed_games: Map::<felt252, bool>,
        _launch_tournament_collections: Vec<ContractAddress>,
        _launch_tournament_games_per_claim: Map::<ContractAddress, u8>,
        _launch_tournament_games_per_collection: u16,
        _launch_tournament_duration_seconds: u64,
        _launch_tournament_participants: Map::<felt252, ContractAddress>,
        _launch_tournament_scores: Map::<ContractAddress, u32>,
        _start_delay_seconds: u64,
        _launch_tournament_game_counts: Map::<ContractAddress, u16>,
        _leaderboard: Leaderboard,
        _payment_token_dispatcher: IERC20Dispatcher,
        _oracle_dispatcher: IPragmaABIDispatcher,
        _previous_free_game_timestamp: Map::<(ContractAddress, u128), u64>,
        _terminal_timestamp: u64,
        _vrf_dispatcher: IRandomnessDispatcher,
        _vrf_premiums_address: ContractAddress,
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        StartGame: StartGame,
        UpgradesAvailable: UpgradesAvailable,
        DiscoveredHealth: DiscoveredHealth,
        DiscoveredGold: DiscoveredGold,
        DiscoveredLoot: DiscoveredLoot,
        DodgedObstacle: DodgedObstacle,
        HitByObstacle: HitByObstacle,
        AmbushedByBeast: AmbushedByBeast,
        DiscoveredBeast: DiscoveredBeast,
        AttackedBeast: AttackedBeast,
        AttackedByBeast: AttackedByBeast,
        SlayedBeast: SlayedBeast,
        FleeFailed: FleeFailed,
        FleeSucceeded: FleeSucceeded,
        AdventurerLeveledUp: AdventurerLeveledUp,
        PurchasedItems: PurchasedItems,
        PurchasedPotions: PurchasedPotions,
        AdventurerUpgraded: AdventurerUpgraded,
        EquipmentChanged: EquipmentChanged,
        EquippedItems: EquippedItems,
        DroppedItems: DroppedItems,
        ItemsLeveledUp: ItemsLeveledUp,
        AdventurerDied: AdventurerDied,
        NewHighScore: NewHighScore,
        RewardDistribution: RewardDistribution,
        PriceChangeEvent: PriceChangeEvent,
        ReceivedLevelSeed: ReceivedLevelSeed,
        RequestedLevelSeed: RequestedLevelSeed,
        RequestedItemSpecialsSeed: RequestedItemSpecialsSeed,
        ReceivedItemSpecialsSeed: ReceivedItemSpecialsSeed,
        UpdatedAdventurerName: UpdatedAdventurerName,
        SetAdventurerObituary: SetAdventurerObituary,
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        ClaimedFreeGame: ClaimedFreeGame,
        NewCollectionTotal: NewCollectionTotal,
    }

    /// @title Constructor
    /// @notice Initializes the contract
    /// @dev This is the constructor for the contract. It is called once when the contract is
    /// deployed.
    ///
    /// @param payment_token: the payment token for the contract
    /// @param eth_address: the address of the ETH dispatcher
    /// @param dao_address: the address of the DAO
    /// @param pg_address: the address of the PG
    /// @param beasts_address: the address of the beasts dispatcher
    /// @param golden_token_address: the address of the golden token dispatcher
    /// @param terminal_timestamp: the timestamp of the terminal timestamp
    /// @param vrf_provider_address: the address of the VRF provider
    /// @param oracle_address: the address of the oracle
    /// @param render_contract: the address of the render contract
    /// @param qualifying_collections: the qualifying collections for the launch tournament
    /// @param launch_tournament_duration_seconds: the duration of the launch tournament in seconds
    /// @param vrf_payments_address: the address of the VRF payments
    /// @param launch_tournament_games_per_collection: the number of games per collection for the
    /// launch tournament
    /// @param start_delay_seconds: the delay before the contract starts accepting games
    /// @param free_vrf_promotion_duration_seconds: the duration of the free VRF promotion
    #[constructor]
    fn constructor(
        ref self: ContractState,
        payment_token: ContractAddress,
        eth_address: ContractAddress,
        dao_address: ContractAddress,
        pg_address: ContractAddress,
        beasts_address: ContractAddress,
        golden_token_address: ContractAddress,
        terminal_timestamp: u64,
        vrf_provider_address: ContractAddress,
        oracle_address: ContractAddress,
        render_contract: ContractAddress,
        qualifying_collections: Array<LaunchTournamentCollections>,
        launch_tournament_duration_seconds: u64,
        vrf_payments_address: ContractAddress,
        launch_tournament_games_per_collection: u16,
        start_delay_seconds: u64,
        free_vrf_promotion_duration_seconds: u64
    ) {
        if payment_token.is_non_zero() {
            let payment_dispatcher = IERC20Dispatcher { contract_address: payment_token };
            self._payment_token_dispatcher.write(payment_dispatcher);
        }

        if eth_address.is_non_zero() {
            let eth_dispatcher = IERC20Dispatcher { contract_address: eth_address };
            self._eth_dispatcher.write(eth_dispatcher);
            // provider vrf provider with approval for all ETH in the contract
            // @dev this is used by pragma to cover callback tx fees
            eth_dispatcher.approve(vrf_provider_address, Bounded::<u256>::MAX);
            // provider vrf payments with approval for all ETH in the contract
            // @dev this is used by pragma to access their vrf premiums
            eth_dispatcher.approve(vrf_payments_address, Bounded::<u256>::MAX);
            // @dev the only reason ETH should be in the contract is to cover VRF costs
        }

        if beasts_address.is_non_zero() {
            let beasts_dispatcher = IBeastsDispatcher { contract_address: beasts_address };
            self._beasts_dispatcher.write(beasts_dispatcher);
        }

        if terminal_timestamp != 0 {
            self._terminal_timestamp.write(terminal_timestamp);
        }

        if vrf_provider_address.is_non_zero() {
            let vrf_dispatcher = IRandomnessDispatcher { contract_address: vrf_provider_address };
            self._vrf_dispatcher.write(vrf_dispatcher);
        }

        if oracle_address.is_non_zero() {
            let oracle_dispatcher = IPragmaABIDispatcher { contract_address: oracle_address };
            self._oracle_dispatcher.write(oracle_dispatcher);
        }

        if render_contract.is_non_zero() {
            self._default_renderer.write(render_contract);
        }

        self._genesis_timestamp.write(get_block_timestamp());

        if launch_tournament_duration_seconds != 0 {
            self._launch_tournament_duration_seconds.write(launch_tournament_duration_seconds);
        }

        if start_delay_seconds != 0 {
            self._start_delay_seconds.write(start_delay_seconds);
        }

        if launch_tournament_games_per_collection != 0 {
            self
                ._launch_tournament_games_per_collection
                .write(launch_tournament_games_per_collection);
        }

        if golden_token_address.is_non_zero() {
            let golden_token_dispatcher = IERC721Dispatcher {
                contract_address: golden_token_address
            };
            self._golden_token_dispatcher.write(golden_token_dispatcher);
        }

        if COST_TO_PLAY != 0 {
            self._cost_to_play.write(COST_TO_PLAY);
        }

        if vrf_payments_address.is_non_zero() {
            self._vrf_premiums_address.write(vrf_payments_address);
        }

        if free_vrf_promotion_duration_seconds != 0 {
            self._free_vrf_promotion_duration_seconds.write(free_vrf_promotion_duration_seconds);
        }

        // @dev base uri isn't used in the current implementation
        self.erc721.initializer("Loot Survivor", "LSVR", "https://token.lootsurvivor.io/");

        // initialize launch tournament
        _initialize_launch_tournament(ref self, qualifying_collections.span());

        // mint genesis adventurers
        _mint_genesis_adventurers(ref self, dao_address, pg_address);
    }

    // ------------------------------------------ //
    // ------------ Impl ------------------------ //
    // ------------------------------------------ //

    #[abi(embed_v0)]
    impl Game of IGame<ContractState> {
        /// @title New Game
        ///
        /// @notice Creates a new game of Loot Survivor
        /// @dev Starts a new game of Loot Survivor with the provided weapon and name. If Golden
        /// Token ID is provided, attempts to process payment with the token. Otherwise, processes
        /// payment with $lords
        ///
        /// @param client_reward_address Address where client rewards should be sent.
        /// @param weapon A u8 representing the weapon to start the game with. Valid options are:
        /// {wand: 12, book: 17, short sword: 46, club: 76}
        /// @param name A u128 value representing the player's name.
        /// @param golden_token_id A u8 representing the ID of the golden token.
        /// @param delay_reveal Whether the game should wait to reveal starting stats till after
        /// starter beast is defeated
        /// @param custom_renderer A ContractAddress to use for rendering
        /// the NFT. Provide 0 to use the default renderer.
        /// @param launch_tournament_winner_token_id A u128 representing the id of a token that won
        /// the launch tournament
        /// @param mint_to A ContractAddress representing the address to mint the adventurer to.
        /// @return A felt252 representing the adventurer id.
        fn new_game(
            ref self: ContractState,
            client_reward_address: ContractAddress,
            weapon: u8,
            name: felt252,
            golden_token_id: u8,
            delay_reveal: bool,
            custom_renderer: ContractAddress,
            launch_tournament_winner_token_id: u128,
            mint_to: ContractAddress
        ) -> felt252 {
            // don't process payment distributions on Katana
            if _network_supports_vrf() {
                // process payment for game and distribute rewards
                if golden_token_id != 0 {
                    _pay_with_special_token(
                        ref self, FreeGameTokenType::GoldenToken, golden_token_id.into()
                    );
                } else if launch_tournament_winner_token_id != 0 {
                    _pay_with_special_token(
                        ref self,
                        FreeGameTokenType::LaunchTournamentChampion,
                        launch_tournament_winner_token_id
                    );
                } else {
                    _process_payment_and_distribute_rewards(ref self, client_reward_address);
                }

                if !_free_vrf_promotion_active(@self) {
                    _pay_for_vrf(@self);
                }
            }

            // assert game is live
            _assert_game_is_live(@self);

            // start the game
            let adventurer_id = _start_game(
                ref self,
                weapon,
                name,
                custom_renderer,
                delay_reveal,
                golden_token_id,
                launch_tournament_winner_token_id,
                mint_to
            );

            // store client provider address
            self._adventurer_client_provider.write(adventurer_id, client_reward_address);

            adventurer_id
        }
        /// @title Explore Function
        ///
        /// @notice Allows an adventurer to explore
        ///
        /// @param adventurer_id A u256 representing the ID of the adventurer.
        /// @param till_beast A boolean flag indicating if the exploration continues until
        /// encountering a beast.
        fn explore(
            ref self: ContractState, adventurer_id: felt252, till_beast: bool
        ) -> Array<ExploreResult> {
            // load player assets
            let (mut adventurer, level_seed, _) = _load_player_assets(@self, adventurer_id);

            let mut bag = _load_bag(@self, adventurer_id);

            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(immutable_adventurer);
            _assert_no_stat_upgrades_available(immutable_adventurer);
            _assert_not_in_battle(immutable_adventurer);
            _assert_entropy_set(@self, adventurer_id);
            _assert_not_awaiting_item_specials(
                @self, adventurer_id, immutable_adventurer, bag.clone()
            );
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // go explore
            let mut explore_results = ArrayTrait::<ExploreResult>::new();
            _explore(
                ref self,
                ref adventurer,
                ref bag,
                ref explore_results,
                adventurer_id,
                level_seed,
                till_beast
            );

            _save_adventurer(ref self, ref adventurer, adventurer_id);

            if bag.mutated {
                _save_bag(ref self, adventurer_id, bag);
            }

            explore_results
        }

        /// @title Attack Function
        ///
        /// @notice Allows an adventurer to attack a beast
        ///
        /// @param adventurer_id A u256 representing the ID of the adventurer.
        /// @param to_the_death A boolean flag indicating if the attack should continue until either
        /// the adventurer or the beast is defeated.
        fn attack(ref self: ContractState, adventurer_id: felt252, to_the_death: bool) {
            // load player assets
            let (mut adventurer, level_seed, _) = _load_player_assets(@self, adventurer_id);

            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(immutable_adventurer);
            _assert_in_battle(immutable_adventurer);
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // Allow Adventurer to attack starter beast before rnd from VRF comes in
            let adventurer_level = adventurer.get_level();
            if (adventurer_level > 1) {
                _assert_entropy_set(@self, adventurer_id);
            }

            // get weapon specials
            let item_specials_seed = _load_adventurer_metadata(@self, adventurer_id)
                .item_specials_seed;
            let weapon_specials = ImplLoot::get_specials(
                adventurer.equipment.weapon.id,
                adventurer.equipment.weapon.get_greatness(),
                item_specials_seed
            );

            // generate xp based randomness seeds
            let (
                beast_seed,
                _,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
                _,
                _
            ) =
                ImplAdventurer::get_randomness(
                adventurer.xp, level_seed
            );

            // get beast based on entropy seeds
            let beast = ImplAdventurer::get_beast(
                adventurer.get_level(),
                adventurer.equipment.weapon.id,
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd
            );

            // get weapon details
            let weapon = ImplLoot::get_item(adventurer.equipment.weapon.id);
            let weapon_combat_spec = CombatSpec {
                tier: weapon.tier,
                item_type: weapon.item_type,
                level: adventurer.equipment.weapon.get_greatness().into(),
                specials: weapon_specials
            };

            _attack(
                ref self,
                ref adventurer,
                weapon_combat_spec,
                adventurer_id,
                level_seed,
                beast,
                beast_seed,
                to_the_death
            );

            _save_adventurer(ref self, ref adventurer, adventurer_id);
        }

        /// @title Flee Function
        ///
        /// @notice Allows an adventurer to flee from a beast
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param to_the_death A boolean flag indicating if the flee attempt should continue until
        /// either the adventurer escapes or is defeated.
        fn flee(ref self: ContractState, adventurer_id: felt252, to_the_death: bool) {
            // load player assets
            let (mut adventurer, level_seed, _) = _load_player_assets(@self, adventurer_id);

            // use an immutable adventurer for assertions
            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(immutable_adventurer);
            _assert_in_battle(immutable_adventurer);
            _assert_not_starter_beast(immutable_adventurer, messages::CANT_FLEE_STARTER_BEAST);
            _assert_dexterity_not_zero(immutable_adventurer);
            _assert_entropy_set(@self, adventurer_id);
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // generate xp based randomness seeds
            let (
                beast_seed,
                _,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
                _,
                _
            ) =
                ImplAdventurer::get_randomness(
                adventurer.xp, level_seed
            );

            // get beast based on entropy seeds
            let beast = ImplAdventurer::get_beast(
                adventurer.get_level(),
                adventurer.equipment.weapon.id,
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd
            );

            // attempt to flee
            _flee(
                ref self, ref adventurer, adventurer_id, level_seed, beast_seed, beast, to_the_death
            );

            // if adventurer died while attempting to flee, process death
            if adventurer.health == 0 {
                _process_adventurer_death(
                    ref self, ref adventurer, adventurer_id, beast.id, 0, false
                );
            }

            _save_adventurer(ref self, ref adventurer, adventurer_id);
        }

        /// @title Equip Function
        ///
        /// @notice Allows an adventurer to equip items from their bag
        /// @player Calling this during battle will result in a beast counter-attack
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param items A u8 array representing the item IDs to equip.
        fn equip(ref self: ContractState, adventurer_id: felt252, items: Array<u8>) {
            // load player assets
            let (mut adventurer, level_seed, mut bag) = _load_player_assets(@self, adventurer_id);

            // assert action is valid
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(adventurer);
            assert(items.len() != 0, messages::NO_ITEMS);
            assert(items.len() <= 8, messages::TOO_MANY_ITEMS);
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // equip items and record the unequipped items for event
            let unequipped_items = _equip_items(
                @self, ref adventurer, ref bag, adventurer_id, items.clone(), false
            );

            __event_EquippedItems(
                ref self, adventurer, adventurer_id, bag, items, unequipped_items,
            );

            // if the adventurer is equipping an item during battle, the beast will counter attack
            if (adventurer.in_battle()) {
                // generate xp based randomness seeds
                let (
                    beast_seed,
                    _,
                    beast_health_rnd,
                    beast_level_rnd,
                    beast_specials1_rnd,
                    beast_specials2_rnd,
                    _,
                    _
                ) =
                    ImplAdventurer::get_randomness(
                    adventurer.xp, level_seed
                );

                // get beast based on entropy seeds
                let beast = ImplAdventurer::get_beast(
                    adventurer.get_level(),
                    adventurer.equipment.weapon.id,
                    beast_seed,
                    beast_health_rnd,
                    beast_level_rnd,
                    beast_specials1_rnd,
                    beast_specials2_rnd
                );

                // get randomness for combat
                let (_, _, beast_crit_hit_rnd, attack_location_rnd) =
                    ImplAdventurer::get_battle_randomness(
                    adventurer.xp, adventurer.battle_action_count, level_seed
                );

                // increment battle action count (ensures each battle action has unique randomness)
                adventurer.increment_battle_action_count();

                // process beast attack
                let beast_battle_details = _beast_attack(
                    ref self,
                    ref adventurer,
                    adventurer_id,
                    beast,
                    beast_seed,
                    beast_crit_hit_rnd,
                    attack_location_rnd,
                    false
                );

                // emit attacked by beast event
                __event_AttackedByBeast(ref self, adventurer, adventurer_id, beast_battle_details);

                // if adventurer died from counter attack, process death
                if (adventurer.health == 0) {
                    _process_adventurer_death(
                        ref self, ref adventurer, adventurer_id, beast.id, 0, false
                    );
                }
            }

            // save adventurer
            _save_adventurer(ref self, ref adventurer, adventurer_id);

            // if the bag was mutated, pack and save it
            if bag.mutated {
                _save_bag(ref self, adventurer_id, bag);
            }
        }

        /// @title Drop Function
        ///
        /// @notice Allows an adventurer to drop equpped items or items from their bag
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param items A u8 Array representing the IDs of the items to drop.
        fn drop(ref self: ContractState, adventurer_id: felt252, items: Array<u8>) {
            // load player assets
            let (mut adventurer, _, mut bag) = _load_player_assets(@self, adventurer_id);

            // assert action is valid (ownership of item is handled in internal function when we
            // iterate over items)
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(adventurer);
            assert(items.len() != 0, messages::NO_ITEMS);
            _assert_not_starter_beast(adventurer, messages::CANT_DROP_DURING_STARTER_BEAST);
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // drop items
            _drop(ref self, ref adventurer, ref bag, adventurer_id, items.clone());

            // emit dropped items event
            __event_DroppedItems(ref self, adventurer, adventurer_id, bag, items);

            // if the adventurer was mutated, save it
            if (adventurer.mutated) {
                _save_adventurer(ref self, ref adventurer, adventurer_id);
            }

            // if the bag was mutated, save it
            if bag.mutated {
                _save_bag(ref self, adventurer_id, bag);
            }
        }

        /// @title Upgrade Function
        ///
        /// @notice Allows an adventurer to upgrade their stats, purchase potions, and buy new
        /// items.
        ///
        /// @param adventurer_id A u256 representing the unique ID of the adventurer.
        /// @param potions A u8 representing the number of potions to purchase
        /// @param stat_upgrades A Stats struct detailing the upgrades the adventurer wants to apply
        /// to their stats.
        /// @param items An array of ItemPurchase detailing the items the adventurer wishes to
        /// purchase during the upgrade.
        fn upgrade(
            ref self: ContractState,
            adventurer_id: felt252,
            potions: u8,
            stat_upgrades: Stats,
            items: Array<ItemPurchase>,
        ) {
            // load player assets
            let (mut adventurer, _, mut bag) = _load_player_assets(@self, adventurer_id);

            let immutable_adventurer = adventurer.clone();

            // assert action is valid
            _assert_ownership(@self, adventurer_id);
            _assert_not_dead(immutable_adventurer);
            _assert_not_in_battle(immutable_adventurer);
            _assert_valid_stat_selection(immutable_adventurer, stat_upgrades);
            _assert_entropy_set(@self, adventurer_id);
            _assert_not_awaiting_item_specials(
                @self, adventurer_id, immutable_adventurer, bag.clone()
            );
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // get number of stat upgrades available before we use them
            let pre_upgrade_stat_points = adventurer.stat_upgrades_available;

            // reset stat upgrades available
            adventurer.stat_upgrades_available = 0;

            // upgrade adventurer's stats
            adventurer.stats.apply_stats(stat_upgrades);

            // if adventurer upgraded vitality
            if stat_upgrades.vitality != 0 {
                // apply health boost
                adventurer.apply_vitality_health_boost(stat_upgrades.vitality);
            }

            // if the player is buying items, process purchases
            if (items.len() != 0) {
                let (purchases, equipped_items, unequipped_items) = _buy_items(
                    @self,
                    ref adventurer,
                    ref bag,
                    adventurer_id,
                    pre_upgrade_stat_points,
                    items.clone()
                );

                // emit purchased item event
                __event_PurchasedItems(ref self, adventurer, adventurer_id, bag, purchases);

                // if purchase required equipment change,
                if (equipped_items.len() != 0) {
                    // emit equipped items event
                    __event_EquippedItems(
                        ref self, adventurer, adventurer_id, bag, equipped_items, unequipped_items,
                    );
                }
            }

            // if the player is buying potions as part of the upgrade, process purchase
            // @dev process potion purchase after items in case item purchases changes item stat
            // boosts
            if potions != 0 {
                _buy_potions(ref self, ref adventurer, adventurer_id, potions);
            }

            // emit adventurer upgraded event
            __event_AdventurerUpgraded(ref self, adventurer, adventurer_id, bag, stat_upgrades);

            // if the upgrade mutated the adventurer's bag
            if bag.mutated {
                _save_bag(ref self, adventurer_id, bag);
            }

            _save_adventurer(ref self, ref adventurer, adventurer_id);
        }
        /// @title Update Cost to Play
        /// @notice Updates the cost to play the game based on the current price of LORDS.
        /// @dev This function fetches the current price of LORDS from the oracle and recalculates
        /// the cost to play the game.
        /// @return The new cost to play the game in u128.
        fn update_cost_to_play(ref self: ContractState) -> u128 {
            let oracle_dispatcher = self._oracle_dispatcher.read();
            let lords_price = get_asset_price_median(
                oracle_dispatcher, DataType::SpotEntry(PRAGMA_LORDS_KEY)
            );

            // target price is the target price in cents * 10^8 because pragma uses 8 decimals for
            // LORDS price
            let target_price = TARGET_PRICE_USD_CENTS.into() * 100000000;

            // new price is the target price (in cents) divided by the current lords price (in
            // cents)
            let new_price = (target_price / (lords_price * 100)) * 1000000000000000000;

            // record previous price
            let previous_price = self._cost_to_play.read();

            // update cost to play
            self._cost_to_play.write(new_price);

            // emit price change event
            let price_change_event = PriceChangeEvent {
                previous_price, new_price, lords_price, changer: get_caller_address()
            };
            self.emit(price_change_event);

            new_price
        }

        /// @title Set a custom nft renderer for an Adventurer
        ///
        /// @notice Allows the owner of an adventurer to set a custom renderer for their NFT.
        ///
        /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
        /// @param render_contract A ContractAddress to use for rendering the NFT. Provide 0 to
        /// switch back to default renderer.
        fn set_adventurer_renderer(
            ref self: ContractState, adventurer_id: felt252, render_contract: ContractAddress
        ) {
            assert(_get_owner(@self, adventurer_id) == get_caller_address(), messages::NOT_OWNER);
            self._adventurer_renderer.write(adventurer_id, render_contract);
        }

        // @title Increase VRF Allowance
        ///
        /// @notice Allows an adventurer to increase their VRF allowance.
        ///
        /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
        /// @param amount A u128 representing the amount of VRF allowance to increase.
        fn increase_vrf_allowance(ref self: ContractState, adventurer_id: felt252, amount: u128) {
            let eth_dispatcher = self._eth_dispatcher.read();
            eth_dispatcher
                .transfer_from(
                    get_caller_address(), starknet::get_contract_address(), amount.into()
                );
            let current_allowance = self._adventurer_vrf_allowance.read(adventurer_id);
            self._adventurer_vrf_allowance.write(adventurer_id, current_allowance + amount);
        }

        /// @title Update Adventurer Name
        /// @notice Allows an adventurer to update their name.
        /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
        /// @param name A felt252 representing the new name of the adventurer.
        fn update_adventurer_name(ref self: ContractState, adventurer_id: felt252, name: felt252) {
            // verify caller owns adventurer
            _assert_ownership(@self, adventurer_id);

            // load adventurer (save gas by not loading boosts)
            let adventurer = _load_adventurer_no_boosts(@self, adventurer_id);

            // no name changes for dead or expired adventurers
            _assert_not_dead(adventurer);
            assert(!_is_expired(@self, adventurer_id), messages::GAME_EXPIRED);

            // update adventurer name
            self._adventurer_name.write(adventurer_id, name);

            // emit updated name event
            self.emit(UpdatedAdventurerName { adventurer_id, name });
        }

        /// @title Set Adventurer Obituary
        /// @notice Allows an adventurer to set their obituary.
        /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
        /// @param obituary A ByteArray representing the obituary of the adventurer.
        fn set_adventurer_obituary(
            ref self: ContractState, adventurer_id: felt252, obituary: ByteArray
        ) {
            // assert caller owners adventurer
            _assert_ownership(@self, adventurer_id);

            // asset adventurer is dead
            let adventurer = _load_adventurer_no_boosts(@self, adventurer_id);
            _assert_is_dead(adventurer);

            // assert obituary has not already been set
            assert(
                self._adventurer_obituary.read(adventurer_id).len() == 0,
                messages::OBITUARY_ALREADY_SET
            );

            // assert OBITUARY_EXPIRY_DAYS have not passed since adventurer's death
            let death_date = _load_adventurer_metadata(@self, adventurer_id).death_date;
            let expiry_date = death_date + (OBITUARY_EXPIRY_DAYS.into() * SECONDS_IN_DAY.into());
            assert(expiry_date > get_block_timestamp(), messages::OBITUARY_WINDOW_CLOSED);

            // set adventurer obituary
            self._adventurer_obituary.write(adventurer_id, obituary.clone());

            // emit obituary set event
            self.emit(SetAdventurerObituary { adventurer_id, obituary });
        }

        /// @title Slay Expired Adventurers
        /// @notice Slay all expired adventurers.
        /// @dev This function is called daily to slay all expired adventurers.
        fn slay_expired_adventurers(ref self: ContractState, adventurer_ids: Array<felt252>) {
            let mut adventurer_index: u32 = 0;
            loop {
                if adventurer_index == adventurer_ids.len() {
                    break;
                }
                let adventurer_id = *adventurer_ids.at(adventurer_index);
                _slay_expired_adventurer(ref self, adventurer_id);
                adventurer_index += 1;
            }
        }


        /// @title Enter Launch Tournament with Signature
        /// @notice Allows an adventurer to enter the launch tournament using qualifying NFTs from a
        /// separate account after verifying the signature.
        /// @param weapon A u8 representing the weapon to start the game with.
        /// @param name A felt252 representing the name of the adventurer.
        /// @param custom_renderer A ContractAddress representing the custom renderer to use for the
        /// adventurer.
        /// @param delay_stat_reveal A bool representing whether to delay the stat reveal.
        /// @param collection_address A ContractAddress representing the address of the NFT
        /// collection.
        /// @param token_id a u128 representing the token ID of the NFT.
        /// @param mint_from A ContractAddress representing the address that will be used for
        /// qualifying collections @param mint_to A ContractAddress representing the address to mint
        /// the games to.
        /// @param signature An Array of felt252 representing the signature of the NFT owner.
        /// @return An Array of felt252 representing the adventurer IDs of the adventurers that were
        /// minted
        fn enter_launch_tournament_with_signature(
            ref self: ContractState,
            weapon: u8,
            name: felt252,
            custom_renderer: ContractAddress,
            delay_stat_reveal: bool,
            collection_address: ContractAddress,
            token_id: u128,
            mint_from: ContractAddress,
            mint_to: ContractAddress,
            signature: Array<felt252>
        ) -> Array<felt252> {
            // generate message hash
            let message = Message { recipient: mint_to };

            // generate signed message using mint_from address
            let hash = message.get_message_hash(mint_from);

            // verify signature
            let is_valid_signature_felt = DualCaseAccount { contract_address: mint_from }
                .is_valid_signature(hash, signature);

            // Check either 'VALID' or True for backwards compatibility
            let is_valid_signature = is_valid_signature_felt == starknet::VALIDATED
                || is_valid_signature_felt == 1;
            assert(is_valid_signature, 'Invalid signature');

            // assert caller is the same as mint_to address
            assert(get_caller_address() == mint_to, 'Caller != mint_to');

            // Call internal function with mint_from as the mint_from which we have verified the
            // caller has access to
            _enter_launch_tournament(
                ref self,
                weapon,
                name,
                custom_renderer,
                delay_stat_reveal,
                collection_address,
                token_id,
                mint_to,
                mint_from
            )
        }

        /// @title Enter Genesis Tournament
        /// @notice Allows an adventurer to enter the launch tournament.
        /// @param weapon A u8 representing the weapon to start the game with.
        /// @param name A felt252 representing the name of the adventurer.
        /// @param custom_renderer A ContractAddress representing the custom renderer to use for the
        /// adventurer.
        /// @param delay_stat_reveal A bool representing whether to delay the stat reveal.
        /// @param collection_address A ContractAddress representing the address of the NFT
        /// collection.
        /// @param token_id a u128 representing the token ID of the NFT.
        /// @param mint_to A ContractAddress representing the address to mint the adventurer to.
        /// @return An Array of felt252 representing the adventurer IDs of the adventurers that were
        fn enter_launch_tournament(
            ref self: ContractState,
            weapon: u8,
            name: felt252,
            custom_renderer: ContractAddress,
            delay_stat_reveal: bool,
            collection_address: ContractAddress,
            token_id: u128,
            mint_to: ContractAddress
        ) -> Array<felt252> {
            _enter_launch_tournament(
                ref self,
                weapon,
                name,
                custom_renderer,
                delay_stat_reveal,
                collection_address,
                token_id,
                mint_to,
                get_caller_address(),
            )
        }

        fn receive_random_words(
            ref self: ContractState,
            requestor_address: ContractAddress,
            request_id: u64,
            random_words: Span<felt252>,
            calldata: Array<felt252>
        ) {
            // verify caller is the vrf contract
            assert(
                get_caller_address() == self._vrf_dispatcher.read().contract_address,
                'caller not vrf contract'
            );

            if _network_supports_vrf() {
                assert(
                    requestor_address == starknet::get_contract_address(),
                    'vrf requestor is not self'
                );
            }

            let rnd = *random_words.at(0);
            let adventurer_id = *calldata.at(0);
            let is_specials_entropy = *calldata.at(1);

            // get adventurer
            let mut adventurer = _load_adventurer(@self, adventurer_id);

            if is_specials_entropy == 0 {
                process_new_level_seed(
                    ref self, requestor_address, ref adventurer, adventurer_id, rnd, request_id
                );
            } else {
                process_item_specials_seed(
                    ref self, adventurer, requestor_address, adventurer_id, rnd, request_id
                );
            }

            if adventurer.mutated {
                _save_adventurer(ref self, ref adventurer, adventurer_id);
            }
        }
        /// @title Set Tournament Winner
        /// @notice Allows anyone to settle the result of the launch tournament
        /// @dev this can only be called after the tournament end time has passed
        /// @dev iterates over the collection scores to find the top score
        /// @dev stores the top score collection in the contract state for easy retrieval
        fn settle_launch_tournament(ref self: ContractState) {
            // assert the tournament has ended
            _assert_launch_tournament_has_ended(@self);

            // assert tournament winner has not already been set
            assert(
                self._launch_tournament_champions_dispatcher.read().contract_address.is_zero(),
                messages::TOURNAMENT_WINNER_ALREADY_SET
            );

            // iterate over _launch_tournament_scores and find top score
            let mut top_score = 0;
            let mut top_score_address = contract_address_const::<0>();

            let num_collections = self._launch_tournament_collections.len();
            let mut collection_index = 0;
            loop {
                if collection_index == num_collections {
                    break;
                }
                let collection_address = self
                    ._launch_tournament_collections
                    .at(collection_index)
                    .read();
                let collection_score = self._launch_tournament_scores.read(collection_address);
                if collection_score > top_score {
                    top_score = collection_score;
                    top_score_address = collection_address;
                }
                collection_index += 1;
            };
            let champions_dispatcher = IERC721Dispatcher { contract_address: top_score_address };

            self._launch_tournament_champions_dispatcher.write(champions_dispatcher);
        }


        // ------------------------------------------ //
        // ------------ View Functions -------------- //
        // ------------------------------------------ //
        fn get_adventurer(self: @ContractState, adventurer_id: felt252) -> Adventurer {
            _load_adventurer(self, adventurer_id)
        }
        fn get_adventurer_name(self: @ContractState, adventurer_id: felt252) -> felt252 {
            self._adventurer_name.read(adventurer_id)
        }
        fn get_adventurer_obituary(self: @ContractState, adventurer_id: felt252) -> ByteArray {
            self._adventurer_obituary.read(adventurer_id)
        }
        fn get_item_specials(self: @ContractState, adventurer_id: felt252) -> Array<ItemSpecial> {
            let mut item_specials: Array<ItemSpecial> = ArrayTrait::<ItemSpecial>::new();
            let specials_seed = _load_adventurer_metadata(self, adventurer_id).item_specials_seed;

            // assert specials seed is not 0
            assert(specials_seed != 0, messages::ITEM_SPECIALS_UNAVAILABLE);

            let mut item_id = 1;
            loop {
                if item_id > 101 {
                    break;
                }

                let special_power = SpecialPowers {
                    special1: ImplLoot::get_suffix(item_id, specials_seed),
                    special2: ImplLoot::get_prefix1(item_id, specials_seed),
                    special3: ImplLoot::get_prefix2(item_id, specials_seed),
                };
                item_specials.append(ItemSpecial { item_id, special_power, });

                item_id += 1;
            };
            item_specials
        }
        fn uses_custom_renderer(self: @ContractState, adventurer_id: felt252) -> bool {
            !self._adventurer_renderer.read(adventurer_id).is_zero()
        }
        fn get_adventurer_renderer(
            self: @ContractState, adventurer_id: felt252
        ) -> ContractAddress {
            _get_adventurer_renderer(self, adventurer_id)
        }
        fn get_adventurer_vrf_allowance(self: @ContractState, adventurer_id: felt252) -> u128 {
            self._adventurer_vrf_allowance.read(adventurer_id)
        }
        fn get_vrf_premiums_address(self: @ContractState) -> ContractAddress {
            self._vrf_premiums_address.read()
        }
        fn get_adventurer_no_boosts(self: @ContractState, adventurer_id: felt252) -> Adventurer {
            _load_adventurer_no_boosts(self, adventurer_id)
        }
        fn get_adventurer_meta(self: @ContractState, adventurer_id: felt252) -> AdventurerMetadata {
            _load_adventurer_metadata(self, adventurer_id)
        }
        fn get_client_provider(self: @ContractState, adventurer_id: felt252) -> ContractAddress {
            self._adventurer_client_provider.read(adventurer_id)
        }
        fn get_bag(self: @ContractState, adventurer_id: felt252) -> Bag {
            _load_bag(self, adventurer_id)
        }
        fn get_market(self: @ContractState, adventurer_id: felt252) -> Array<u8> {
            let adventurer = _load_adventurer(self, adventurer_id);
            _get_market(self, adventurer_id, adventurer.stat_upgrades_available)
        }

        fn get_potion_price(self: @ContractState, adventurer_id: felt252) -> u16 {
            _get_potion_price(self, adventurer_id)
        }
        fn get_item_price(self: @ContractState, adventurer_id: felt252, item_id: u8) -> u16 {
            _get_item_price(self, adventurer_id, item_id)
        }
        fn get_attacking_beast(self: @ContractState, adventurer_id: felt252) -> Beast {
            _get_attacking_beast(self, adventurer_id)
        }
        // fn get_beast_type(self: @ContractState, beast_id: u8) -> u8 {
        //     ImplCombat::type_to_u8(ImplBeast::get_type(beast_id))
        // }
        // fn get_beast_tier(self: @ContractState, beast_id: u8) -> u8 {
        //     ImplCombat::tier_to_u8(ImplBeast::get_tier(beast_id))
        // }
        fn get_leaderboard(self: @ContractState) -> Leaderboard {
            self._leaderboard.read()
        }
        fn get_game_count(self: @ContractState) -> felt252 {
            self._game_count.read()
        }
        fn obstacle_critical_hit_chance(self: @ContractState, adventurer_id: felt252) -> u8 {
            let adventurer = self._adventurer.read(adventurer_id);
            ImplAdventurer::get_dynamic_critical_hit_chance(adventurer.get_level())
        }
        fn beast_critical_hit_chance(
            self: @ContractState, adventurer_id: felt252, is_ambush: bool
        ) -> u8 {
            let adventurer = self._adventurer.read(adventurer_id);
            ImplBeast::get_critical_hit_chance(adventurer.get_level(), is_ambush)
        }
        fn get_cost_to_play(self: @ContractState) -> u128 {
            _get_cost_to_play(self)
        }

        fn free_game_available(
            self: @ContractState, token_type: FreeGameTokenType, token_id: u128
        ) -> bool {
            _free_game_available(self, token_type, token_id)
        }
        fn free_vrf_promotion_active(self: @ContractState) -> bool {
            _free_vrf_promotion_active(self)
        }
        fn is_launch_tournament_active(self: @ContractState) -> bool {
            _is_launch_tournament_active(self)
        }
        fn get_launch_tournament_winner(self: @ContractState) -> ContractAddress {
            _get_launch_tournament_winner(self)
        }
        fn get_launch_tournament_end_time(self: @ContractState) -> u64 {
            _launch_tournament_end_time(self)
        }
        fn get_start_time(self: @ContractState) -> u64 {
            let genesis_timestamp = self._genesis_timestamp.read();
            let start_delay = self._start_delay_seconds.read();
            genesis_timestamp + start_delay
        }
    }

    // ------------------------------------------ //
    // ------------ Internal Functions ---------- //
    // ------------------------------------------ //

    fn _mint_genesis_adventurers(
        ref self: ContractState, dao_address: ContractAddress, pg_address: ContractAddress
    ) {
        _start_game(
            ref self,
            ItemId::Wand,
            'Genesis Adventurer',
            contract_address_const::<0>(),
            true,
            0,
            0,
            pg_address
        );

        _start_game(
            ref self,
            ItemId::Book,
            'Bibliomancer',
            contract_address_const::<0>(),
            true,
            0,
            0,
            dao_address
        );

        _start_game(
            ref self,
            ItemId::ShortSword,
            'GLHF',
            contract_address_const::<0>(),
            true,
            0,
            0,
            pg_address
        );
    }
    fn _free_vrf_promotion_active(self: @ContractState) -> bool {
        let current_timestamp = starknet::get_block_info().unbox().block_timestamp;
        let genesis_timestamp = self._genesis_timestamp.read();
        let free_vrf_promotion_duration_seconds = self._free_vrf_promotion_duration_seconds.read();
        current_timestamp <= genesis_timestamp + free_vrf_promotion_duration_seconds
    }

    fn _enter_launch_tournament(
        ref self: ContractState,
        weapon: u8,
        name: felt252,
        custom_renderer: ContractAddress,
        delay_stat_reveal: bool,
        collection_address: ContractAddress,
        token_id: u128,
        mint_to: ContractAddress,
        owner: ContractAddress
    ) -> Array<felt252> {
        // assert game terminal time has not been reached
        _assert_launch_tournament_is_active(@self);

        // assert game is live
        _assert_game_is_live(@self);

        // assert the nft collection is part of the set of free game nft collections
        _assert_is_qualifying_nft(@self, collection_address);

        // assert caller owns nft
        _assert_nft_ownership(@self, collection_address, token_id, owner);

        // get hash of collection and token id
        let token_hash = _get_token_hash(@self, collection_address, token_id);

        // assert token has not already claimed free game
        _assert_token_not_claimed(@self, token_hash);

        // assert the total number of games for this collection is below the tournament limit
        let games_claimed_for_collection = self
            ._launch_tournament_game_counts
            .read(collection_address);

        let max_games_per_collection = self._launch_tournament_games_per_collection.read();

        assert(
            games_claimed_for_collection < max_games_per_collection,
            messages::COLLECTION_OUT_OF_GAMES
        );

        // get the number of games allowed per collection
        let max_claimable_games = self._launch_tournament_games_per_claim.read(collection_address);

        // adjust for the case where the collection doesn't have enough games remaining to claim
        // the full amount of games they are allowed
        let claimable_games = if games_claimed_for_collection
            + max_claimable_games.into() > max_games_per_collection {
            // if there aren't enough games remaining to claim the max, claim the remaining
            max_games_per_collection - games_claimed_for_collection.into()
        } else {
            // if there are enough games remaining, claim max
            max_claimable_games.into()
        };

        // increment game count for this collection
        self
            ._launch_tournament_game_counts
            .write(collection_address, games_claimed_for_collection + claimable_games);

        // set token as claimed
        self._launch_tournament_claimed_games.write(token_hash, true);

        // iterate over the number of claimable games
        let mut adventurer_ids: Array<felt252> = ArrayTrait::<felt252>::new();
        let mut claim_count = 0;
        loop {
            if claim_count == claimable_games {
                break;
            }

            // mint/start the game
            let adventurer_id = _start_game(
                ref self, weapon, name, custom_renderer, delay_stat_reveal, 0, 0, mint_to
            );

            // record the collection the adventurer is playing for
            self._launch_tournament_participants.write(adventurer_id, collection_address);

            // emit claimed free game event
            __event_ClaimedFreeGame(ref self, adventurer_id, collection_address, token_id);

            // add adventurer id to array of new game ids
            adventurer_ids.append(adventurer_id);

            // increment game index
            claim_count += 1;
        };

        // return the array of new game ids
        adventurer_ids
    }

    /// @title Get Adventurer Renderer
    /// @notice Retrieves the renderer for an adventurer.
    /// @dev If the adventurer has a custom renderer, it returns that. Otherwise, it returns the
    /// default renderer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return A ContractAddress representing the renderer for the adventurer.
    fn _get_adventurer_renderer(self: @ContractState, adventurer_id: felt252) -> ContractAddress {
        let custom_renderer = self._adventurer_renderer.read(adventurer_id);
        if custom_renderer.is_zero() {
            self._default_renderer.read()
        } else {
            custom_renderer
        }
    }

    /// @title Set Adventurer Rank at Death (internal)
    /// @notice Allows an adventurer to set their rank at death.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param rank_at_death A u8 representing the rank at death of the adventurer.
    fn _record_adventurer_rank_at_death(
        ref self: ContractState, adventurer_id: felt252, rank_at_death: u8
    ) {
        let mut adventurer_meta = _load_adventurer_metadata(@self, adventurer_id);
        adventurer_meta.rank_at_death = rank_at_death;
        self._adventurer_meta.write(adventurer_id, adventurer_meta);
    }

    /// @title Slay Expired Adventurers (internal)
    /// @notice Slay all expired adventurers.
    /// @dev This function is called daily to slay all expired adventurers.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _slay_expired_adventurer(ref self: ContractState, adventurer_id: felt252) {
        // unpack adventurer from storage (no need for stat boosts)
        let mut adventurer = _load_adventurer_no_boosts(@self, adventurer_id);

        // assert adventurer is not already dead
        _assert_not_dead(adventurer);

        // assert adventurer is expired
        assert(_is_expired(@self, adventurer_id), messages::ADVENTURER_NOT_EXPIRED);

        // slay adventurer by setting health to 0
        adventurer.health = 0;

        // handle adventurer death
        _process_adventurer_death(ref self, ref adventurer, adventurer_id, 0, 0, true);

        // save adventurer (gg)
        _save_adventurer_no_boosts(ref self, adventurer, adventurer_id);
    }

    /// @title Process Item Specials Randomness (internal)
    /// @notice Processes the randomness for item specials and emits an event.
    /// @dev This function is called when the randomness for item specials is received.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param requestor_address A ContractAddress representing the address of the requestor.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item_specials_seed A felt252 representing the seed for item specials.
    /// @param request_id A u64 representing the request ID.
    fn process_item_specials_seed(
        ref self: ContractState,
        adventurer: Adventurer,
        requestor_address: ContractAddress,
        adventurer_id: felt252,
        item_specials_seed: felt252,
        request_id: u64
    ) {
        // downscale the felt252 to a u16 as that's adaquate amount of entropy for item specials
        // and will make processing the item specials significantly more eficient than using a
        // felt252
        let item_specials_seed_u256: u256 = item_specials_seed.into();
        let item_specials_seed_u16: u16 = (item_specials_seed_u256 % TWO_POW_16.into())
            .try_into()
            .unwrap();
        _set_item_specials(ref self, adventurer_id, item_specials_seed_u16);
        _event_ReceivedItemSpecialsSeed(
            ref self, adventurer_id, requestor_address, item_specials_seed, request_id
        );
        // get adventurer equipment

        let items_leveled_up = ImplAdventurer::get_items_leveled_up(
            adventurer.equipment, item_specials_seed_u16
        );
        __event_ItemsLeveledUp(ref self, adventurer, adventurer_id, items_leveled_up);
    }

    /// @title Process VRF Randomness
    /// @notice Processes the randomness for VRF and emits an event.
    /// @dev This function is called when the randomness for VRF is received.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param requestor_address A ContractAddress representing the address of the requestor.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param level_seed A felt252 representing the entropy for the adventurer.
    /// @param request_id A u64 representing the request ID.
    fn process_new_level_seed(
        ref self: ContractState,
        requestor_address: ContractAddress,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        level_seed: felt252,
        request_id: u64
    ) {
        let level_seed_u256: u256 = level_seed.into();
        let level_seed_u64 = (level_seed_u256 % MAX_U64.into()).try_into().unwrap();
        _set_level_seed(ref self, adventurer_id, level_seed_u64);
        __event_ReceivedLevelSeed(ref self, adventurer_id, requestor_address, request_id);

        let adventurer_level = adventurer.get_level();

        // If the adventurer is on level 2, they are waiting on this entropy to come in for the
        // market to be available
        if adventurer_level == 2 {
            reveal_starting_stats(ref adventurer, adventurer_id, level_seed_u64);
            __event_UpgradesAvailable(ref self, adventurer, adventurer_id);
        } else if adventurer_level > 2 {
            // emit upgrades available event
            __event_UpgradesAvailable(ref self, adventurer, adventurer_id);
        }
    }

    /// @title Process Starting Entropy
    /// @notice Processes the starting entropy for the adventurer and emits an event.
    /// @dev This function is called when the starting entropy for the adventurer is received.
    /// @param adventurer A reference to the Adventurer object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param level_seed A u64 representing the level seed for the adventurer.
    fn reveal_starting_stats(ref adventurer: Adventurer, adventurer_id: felt252, level_seed: u64) {
        // reveal and apply starting stats
        adventurer.stats = ImplStats::generate_starting_stats(level_seed);

        // increase adventurer's health for any vitality they received
        adventurer.health += adventurer.stats.get_max_health() - STARTING_HEALTH.into();

        // flag adventurer as mutated so it gets saved at end of execution
        adventurer.mutated = true;
    }

    /// @title Get Asset Price Median
    /// @notice Retrieves the median price of an asset from the Pragma Oracle.
    /// @dev This function fetches the median price of an asset from the Pragma Oracle.
    /// @param oracle_dispatcher A IPragmaABIDispatcher representing the Pragma Oracle dispatcher.
    /// @param asset A DataType representing the asset to retrieve the price for.
    /// @return A u128 representing the median price of the asset.
    fn get_asset_price_median(oracle_dispatcher: IPragmaABIDispatcher, asset: DataType) -> u128 {
        let output: PragmaPricesResponse = oracle_dispatcher
            .get_data(asset, AggregationMode::Median(()));
        return output.price;
    }

    /// @title Request Randomness
    /// @notice Requests randomness for the adventurer and emits an event.
    /// @dev This function is called when the randomness for VRF is received.
    /// @param self A reference to the ContractState object.
    /// @param seed A u64 representing the seed for the randomness.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item_specials A u8 representing the item specials.
    fn _request_randomness(
        ref self: ContractState, seed: u64, adventurer_id: felt252, item_specials: u8
    ) {
        // pass adventurer id and item specials flag to vrf as calldata
        // so when we receive the vrf callback, we know which adventurer to update
        // and if the callback is for item specials or not
        let calldata = array![adventurer_id, item_specials.into()];

        // Get base vrf callback fee
        let max_callback_fee_base = _get_vrf_max_callback_fee(@self);

        // Get adventurer specific vrf callback fee
        let player_vrf_allowance = self._adventurer_vrf_allowance.read(adventurer_id);

        // Calculate total callback fee
        let max_callback_fee_total = max_callback_fee_base + player_vrf_allowance;

        // Request the randomness
        let vrf_dispatcher = self._vrf_dispatcher.read();
        vrf_dispatcher
            .request_random(
                seed,
                starknet::get_contract_address(),
                max_callback_fee_total,
                PRAGMA_PUBLISH_DELAY.into(),
                PRAGMA_NUM_WORDS.into(),
                calldata
            );

        // zero out player vrf allowance
        if player_vrf_allowance != 0 {
            self._adventurer_vrf_allowance.write(adventurer_id, 0);
        }
    }

    /// @title Assert Terminal Time Not Reached
    /// @notice Asserts that the terminal time has not been reached.
    /// @dev This function checks if the terminal time has been reached and asserts if it has.
    /// @param self A reference to the ContractState object.
    fn _assert_terminal_time_not_reached(self: @ContractState) {
        let current_timestamp = starknet::get_block_info().unbox().block_timestamp;
        let terminal_timestamp = self._terminal_timestamp.read();
        assert(
            terminal_timestamp == 0 || current_timestamp < terminal_timestamp,
            messages::TERMINAL_TIME_REACHED
        );
    }

    /// @title Process Beast Death
    /// @notice Processes the death of a beast and emits an event.
    /// @dev This function is called when a beast is slain.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param beast A reference to the Beast object.
    /// @param beast_seed A u128 representing the seed of the beast.
    /// @param damage_dealt A u16 representing the damage dealt to the beast.
    /// @param critical_hit A boolean representing whether the attack was a critical hit.
    fn _process_beast_death(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        beast: Beast,
        beast_seed: u32,
        damage_dealt: u16,
        critical_hit: bool
    ) {
        // zero out beast health
        adventurer.beast_health = 0;

        // reset battle action count to reset battle randomness
        adventurer.battle_action_count = 0;

        // get gold reward and increase adventurers gold
        let gold_earned = beast.get_gold_reward();
        let ring_bonus = adventurer.equipment.ring.jewelry_gold_bonus(gold_earned);
        adventurer.increase_gold(gold_earned + ring_bonus);

        // get xp reward and increase adventurers xp
        let xp_earned_adventurer = beast.get_xp_reward(adventurer.get_level());
        let (previous_level, new_level) = adventurer.increase_adventurer_xp(xp_earned_adventurer);

        // items use adventurer xp with an item multplier so they level faster than Adventurer
        let xp_earned_items = xp_earned_adventurer * ITEM_XP_MULTIPLIER_BEASTS.into();
        // assigning xp to items is more complex so we delegate to an internal function
        let items_leveled_up = _grant_xp_to_equipped_items(
            ref self, ref adventurer, adventurer_id, xp_earned_items
        );

        // emit slayed beast event
        __event_SlayedBeast(
            ref self,
            adventurer,
            adventurer_id,
            beast_seed,
            beast,
            damage_dealt,
            critical_hit,
            xp_earned_adventurer,
            xp_earned_items,
            gold_earned
        );

        // if any items leveled up
        if items_leveled_up.len() != 0 {
            // emit event
            __event_ItemsLeveledUp(ref self, adventurer, adventurer_id, items_leveled_up);
        }

        // if adventurer gained stat points
        if (adventurer.stat_upgrades_available != 0) {
            // emit events
            _process_level_up(ref self, ref adventurer, adventurer_id, previous_level, new_level);
        }

        // if beast beast level is above collectible threshold
        if beast.combat_spec.level >= BEAST_SPECIAL_NAME_LEVEL_UNLOCK.into()
            && _network_supports_vrf() {
            // mint beast to owner of the adventurer or controller delegate if set
            let mint_to_address = _get_delegate_or_owner(@self, adventurer_id);
            _mint_beast(@self, beast, mint_to_address);
        }
    }

    /// @title Mint Beast
    /// @notice Mints a beast and emits an event.
    /// @dev This function is called when a beast is slain.
    /// @param self A reference to the ContractState object.
    /// @param beast A reference to the Beast object.
    /// @param to_address A ContractAddress representing the address to mint the beast to.
    fn _mint_beast(self: @ContractState, beast: Beast, to_address: ContractAddress) {
        let beasts_dispatcher = self._beasts_dispatcher.read();

        let is_beast_minted = beasts_dispatcher
            .isMinted(
                beast.id, beast.combat_spec.specials.special2, beast.combat_spec.specials.special3
            );

        let beasts_minter = beasts_dispatcher.getMinter();

        if !is_beast_minted && beasts_minter == starknet::get_contract_address() {
            beasts_dispatcher
                .mint(
                    to_address,
                    beast.id,
                    beast.combat_spec.specials.special2,
                    beast.combat_spec.specials.special3,
                    beast.combat_spec.level,
                    beast.starting_health
                );
        }
    }

    /// @title Process Adventurer Death
    /// @notice Processes the death of an adventurer and emits an event.
    /// @dev This function is called when an adventurer dies.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param beast_id A u8 representing the ID of the beast that killed the adventurer.
    /// @param obstacle_id A u8 representing the ID of the obstacle that killed the adventurer.
    fn _process_adventurer_death(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        beast_id: u8,
        obstacle_id: u8,
        killed_by_old_age: bool,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };

        let death_details = DeathDetails {
            killed_by_beast: beast_id, killed_by_obstacle: obstacle_id, killed_by_old_age,
        };

        _set_death_date(ref self, adventurer_id);

        __event_AdventurerDied(ref self, AdventurerDied { adventurer_state, death_details });

        // and adventurer got a top score
        if _is_top_score(@self, adventurer.xp) {
            // update the leaderboard
            _update_leaderboard(ref self, adventurer_id, adventurer);
        }

        // if this game is part of the launch tournament and the tournament is still active
        let collection_address = self._launch_tournament_participants.read(adventurer_id);
        if collection_address.is_non_zero() && _is_launch_tournament_active(@self) {
            // get previous score for the collection
            let previous_score = self._launch_tournament_scores.read(collection_address);

            // calculate new score
            let new_score = previous_score + adventurer.xp.into();

            // update the score
            self._launch_tournament_scores.write(collection_address, new_score);

            // get number of games played for this collection
            let games_played = self._launch_tournament_game_counts.read(collection_address);

            // emit event
            __event_NewCollectionTotal(ref self, collection_address, new_score, games_played);
        }
    }

    fn _set_death_date(ref self: ContractState, adventurer_id: felt252) {
        let mut adventurer_meta = self._adventurer_meta.read(adventurer_id);
        adventurer_meta.death_date = get_block_timestamp();
        self._adventurer_meta.write(adventurer_id, adventurer_meta);
    }

    fn _set_level_seed(ref self: ContractState, adventurer_id: felt252, seed: u64) {
        let mut adventurer_meta = self._adventurer_meta.read(adventurer_id);
        adventurer_meta.level_seed = seed;
        self._adventurer_meta.write(adventurer_id, adventurer_meta);
    }

    fn _set_item_specials(
        ref self: ContractState, adventurer_id: felt252, item_specials_seed: u16
    ) {
        let mut adventurer_meta = self._adventurer_meta.read(adventurer_id);

        // reserve zero for unset item specials
        if item_specials_seed == 0 {
            adventurer_meta.item_specials_seed = item_specials_seed + 1;
        } else {
            adventurer_meta.item_specials_seed = item_specials_seed;
        }

        self._adventurer_meta.write(adventurer_id, adventurer_meta);
    }

    fn _calculate_payout(bp: u128, price: u128) -> u128 {
        (bp * price) / 1000
    }

    fn _get_cost_to_play(self: @ContractState) -> u128 {
        self._cost_to_play.read()
    }

    /// @title Get Reward Distribution
    /// @notice Retrieves the reward distribution for the game and emits an event.
    /// @dev This function calculates the reward distribution based on the cost to play and the game
    /// count.
    /// @param self A reference to the ContractState object.
    /// @return Rewards The reward distribution for the game.
    fn _get_reward_distribution(self: @ContractState) -> Rewards {
        let cost_to_play = self._cost_to_play.read();

        let mut rewards = Rewards {
            BIBLIO: _calculate_payout(REWARD_DISTRIBUTIONS_BP::CREATOR, cost_to_play),
            PG: 0,
            CLIENT_PROVIDER: _calculate_payout(
                REWARD_DISTRIBUTIONS_BP::CLIENT_PROVIDER, cost_to_play
            ),
            FIRST_PLACE: _calculate_payout(REWARD_DISTRIBUTIONS_BP::FIRST_PLACE, cost_to_play),
            SECOND_PLACE: _calculate_payout(REWARD_DISTRIBUTIONS_BP::SECOND_PLACE, cost_to_play),
            THIRD_PLACE: _calculate_payout(REWARD_DISTRIBUTIONS_BP::THIRD_PLACE, cost_to_play),
        };

        // alternate contract rewards between pg and bibio
        // @dev this is functional equivalent to splitting rewards but saves an erc20 transfer
        let game_count = self._game_count.read();
        let (_, r) = integer::U256DivRem::div_rem(game_count.into(), 2);
        if r == 1 {
            rewards.PG = rewards.BIBLIO;
            rewards.BIBLIO = 0;
        }

        rewards
    }

    /// @title Pay for VRF
    /// @notice Pays for VRF and emits an event.
    /// @dev This function transfers $1 worth of ETH from the caller to the game contract to cover
    /// VRF premiums and gas for callbacks.
    /// @param self A reference to the ContractState object.
    fn _pay_for_vrf(self: @ContractState) {
        let eth_dispatcher = self._eth_dispatcher.read();
        let one_dollar_wei = _dollar_to_wei(self, VRF_COST_PER_GAME.into());

        // transfer $1 worth of ETH from user to game contract to cover VRF premiums and gas for
        // callbacks
        eth_dispatcher
            .transfer_from(
                get_caller_address(), starknet::get_contract_address(), one_dollar_wei.into()
            );
    }

    /// @title Convert Dollar to Wei
    /// @notice Converts a dollar amount to Wei based on the current price of ETH.
    /// @dev This function fetches the current price of ETH from the Pragma Oracle and converts the
    /// dollar amount to Wei.
    /// @param self A reference to the ContractState object.
    /// @param usd A u128 representing the dollar amount to convert to Wei.
    /// @return A u128 representing the converted Wei amount.
    fn _dollar_to_wei(self: @ContractState, usd: u128) -> u128 {
        let oracle_dispatcher = self._oracle_dispatcher.read();
        let response = oracle_dispatcher.get_data_median(DataType::SpotEntry('ETH/USD'));
        assert(response.price > 0, messages::FETCHING_ETH_PRICE_ERROR);
        (usd * pow(10, response.decimals.into()) * 1000000000000000000)
            / (response.price * 100000000)
    }

    fn _get_dao_address(self: @ContractState) -> ContractAddress {
        _get_owner(self, DAO_CONTRACT_REWARD_ADVENTURER.into())
    }

    fn _get_pg_address(self: @ContractState) -> ContractAddress {
        _get_owner(self, PG_CONTRACT_REWARD_ADVENTURER.into())
    }

    /// @title Process Payment and Distribute Rewards
    /// @notice Processes the payment and distributes the rewards to the appropriate addresses.
    /// @dev This function is called when the payment is processed and the rewards are distributed.
    /// @param self A reference to the ContractState object.
    /// @param client_address A ContractAddress representing the address of the client.
    fn _process_payment_and_distribute_rewards(
        ref self: ContractState, client_address: ContractAddress
    ) {
        let leaderboard = self._leaderboard.read();
        let cost_to_play = self._cost_to_play.read();
        let payment_dispatcher = self._payment_token_dispatcher.read();

        // if the third place score is less than the minimum score for payouts
        if leaderboard.third.xp < MINIMUM_SCORE_FOR_PAYOUTS {
            // send tokens to PG address
            // @dev this is expected to be a trivial amount and exists to remove incentive to play
            // and die fast
            let pg_address = _get_pg_address(@self);
            payment_dispatcher.transfer_from(get_caller_address(), pg_address, cost_to_play.into());
        } else {
            // if payouts are active, calculate rewards
            let rewards = _get_reward_distribution(@self);

            // get owner addresses for each place
            let first_place_address = _get_owner(@self, leaderboard.first.adventurer_id.into());
            let second_place_address = _get_owner(@self, leaderboard.second.adventurer_id.into());
            let third_place_address = _get_owner(@self, leaderboard.third.adventurer_id.into());

            // if client provider is not zero, transfer rewards
            if rewards.CLIENT_PROVIDER != 0 {
                payment_dispatcher
                    .transfer_from(
                        get_caller_address(), client_address, rewards.CLIENT_PROVIDER.into()
                    );
            }

            if rewards.BIBLIO != 0 {
                let dao_address = _get_dao_address(@self);
                payment_dispatcher
                    .transfer_from(get_caller_address(), dao_address, rewards.BIBLIO.into());
            }

            // if pg is not zero, transfer rewards
            if rewards.PG != 0 {
                let pg_address = _get_pg_address(@self);
                payment_dispatcher
                    .transfer_from(get_caller_address(), pg_address, rewards.PG.into());
            }

            // if first place is not zero, transfer rewards
            if rewards.FIRST_PLACE != 0 {
                payment_dispatcher
                    .transfer_from(
                        get_caller_address(), first_place_address, rewards.FIRST_PLACE.into()
                    );
            }

            // if second place is not zero, transfer rewards
            if rewards.SECOND_PLACE != 0 {
                payment_dispatcher
                    .transfer_from(
                        get_caller_address(), second_place_address, rewards.SECOND_PLACE.into()
                    );
            }

            // if third place is not zero, transfer rewards
            if rewards.THIRD_PLACE != 0 {
                payment_dispatcher
                    .transfer_from(
                        get_caller_address(), third_place_address, rewards.THIRD_PLACE.into()
                    );
            }

            // emit event
            __event_RewardDistribution(ref self, rewards, leaderboard, client_address);
        }
    }

    /// @title Start Game
    /// @notice Starts a new game and emits an event.
    /// @dev This function is called when a new game is started.
    /// @param self A reference to the ContractState object.
    /// @param weapon A u8 representing the weapon for the adventurer.
    /// @param name A felt252 representing the name of the adventurer.
    /// @param custom_renderer A ContractAddress representing the address of the custom renderer.
    /// @param delay_stat_reveal A bool representing whether to delay the stat reveal until the
    /// starter beast is defeated.
    /// @param golden_token_id A u8 representing the golden token id of the adventurer.
    /// @param launch_tournament_winner_token_id A u128 representing the token id of the launch
    /// @param mint_to A ContractAddress representing the address to mint the adventurer to.
    /// @return A felt252 representing the adventurer id.
    fn _start_game(
        ref self: ContractState,
        weapon: u8,
        name: felt252,
        custom_renderer: ContractAddress,
        delay_stat_reveal: bool,
        golden_token_id: u8,
        launch_tournament_winner_token_id: u128,
        mint_to: ContractAddress
    ) -> felt252 {
        // assert game terminal time has not been reached
        _assert_terminal_time_not_reached(@self);

        // assert provided weapon
        _assert_valid_starter_weapon(weapon);

        // increment adventurer id (first adventurer is id 1)
        let adventurer_id = self._game_count.read() + 1;

        // generate a new adventurer using the provided started weapon
        let mut adventurer = ImplAdventurer::new(weapon);

        // create meta data for the adventurer
        let adventurer_meta = ImplAdventurerMetadata::new(
            get_block_timestamp().into(),
            delay_stat_reveal,
            golden_token_id,
            launch_tournament_winner_token_id
        );

        let beast_battle_details = _starter_beast_ambush(ref adventurer, adventurer_id, weapon);

        // if we're not running on Katana, request randomness from VRF as soon as game starts
        if !delay_stat_reveal && _network_supports_vrf() {
            _request_randomness(ref self, adventurer_id.try_into().unwrap(), adventurer_id, 0);
        }

        // increment the adventurer id counter
        self._game_count.write(adventurer_id);

        // if a custom renderer was provided
        if custom_renderer.is_non_zero() {
            // store it
            self._adventurer_renderer.write(adventurer_id, custom_renderer);
        }

        // store the original minter of the adventurer
        self._adventurer_minter.write(adventurer_id, get_caller_address());

        // if a mint to address was provided, mint the adventurer to that address
        if mint_to.is_non_zero() {
            self.erc721.mint(mint_to, adventurer_id.into());
        } else {
            // otherwise mint to the caller
            self.erc721.mint(get_caller_address(), adventurer_id.into());
        }

        // emit events
        __event_StartGame(
            ref self, adventurer, adventurer_id, adventurer_meta, name, custom_renderer
        );
        __event_AmbushedByBeast(ref self, adventurer, adventurer_id, beast_battle_details);

        // save adventurer details
        _save_adventurer_name(ref self, adventurer_id, name);
        _save_adventurer_metadata(ref self, adventurer_id, adventurer_meta);
        _save_adventurer_no_boosts(ref self, adventurer, adventurer_id);

        // return the adventurer id
        adventurer_id
    }

    /// @title Starter Beast Ambush
    /// @notice Simulates a beast ambush for the adventurer and returns the battle details.
    /// @dev This function simulates a beast ambush for the adventurer and returns the battle
    /// details.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param starting_weapon A u8 representing the starting weapon for the adventurer.
    /// @return BattleDetails The battle details for the ambush.
    fn _starter_beast_ambush(
        ref adventurer: Adventurer, adventurer_id: felt252, starting_weapon: u8
    ) -> BattleDetails {
        // starter beast will always be weak against starter weapon so we don't need to
        // expend a lot of resources to generate strong entropy. Instead just downres
        // the adventurer id to u32 and use that for beast seed
        let level_seed_u256: u256 = adventurer_id.try_into().unwrap();
        let beast_seed = (level_seed_u256 % TWO_POW_32.into()).try_into().unwrap();

        // generate starter beast which will have weak armor against the adventurers starter weapon
        let starter_beast = ImplBeast::get_starter_beast(
            ImplLoot::get_type(starting_weapon), beast_seed
        );

        // spoof a beast ambush by deducting health from the adventurer
        adventurer.decrease_health(STARTER_BEAST_ATTACK_DAMAGE);

        // return battle details
        BattleDetails {
            seed: beast_seed,
            id: starter_beast.id,
            beast_specs: starter_beast.combat_spec,
            damage: STARTER_BEAST_ATTACK_DAMAGE,
            critical_hit: false,
            location: 2
        }
    }

    /// @title Explore
    /// @notice Allows the adventurer to explore the world and encounter beasts, obstacles, or
    /// discoveries.
    /// @dev This function is called when the adventurer explores the world.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param level_seed A felt252 representing the entropy for the adventurer.
    /// @param explore_till_beast A bool representing whether to explore until a beast is
    /// encountered.
    fn _explore(
        ref self: ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        ref explore_results: Array<ExploreResult>,
        adventurer_id: felt252,
        level_seed: u64,
        explore_till_beast: bool
    ) {
        let (rnd1_u32, _, rnd3_u16, rnd4_u16, rnd5_u8, rnd6_u8, rnd7_u8, explore_rnd) =
            ImplAdventurer::get_randomness(
            adventurer.xp, level_seed
        );

        // go exploring
        let explore_result = ImplAdventurer::get_random_explore(explore_rnd);
        explore_results.append(explore_result);
        match explore_result {
            ExploreResult::Beast(()) => {
                _beast_encounter(
                    ref self,
                    ref adventurer,
                    adventurer_id,
                    seed: rnd1_u32,
                    health_rnd: rnd3_u16,
                    level_rnd: rnd4_u16,
                    dmg_location_rnd: rnd5_u8,
                    crit_hit_rnd: rnd6_u8,
                    ambush_rnd: rnd7_u8,
                    specials1_rnd: rnd5_u8, // use same entropy for crit hit, initial attack location, and beast specials
                    specials2_rnd: rnd6_u8 // to create some fun organic lore for the beast special names
                );
            },
            ExploreResult::Obstacle(()) => {
                _obstacle_encounter(
                    ref self,
                    ref adventurer,
                    adventurer_id,
                    seed: rnd1_u32,
                    level_rnd: rnd4_u16,
                    dmg_location_rnd: rnd5_u8,
                    crit_hit_rnd: rnd6_u8,
                    dodge_rnd: rnd7_u8,
                );
            },
            ExploreResult::Discovery(()) => {
                _process_discovery(
                    ref self,
                    ref adventurer,
                    ref bag,
                    adventurer_id,
                    discovery_type_rnd: rnd5_u8,
                    amount_rnd1: rnd6_u8,
                    amount_rnd2: rnd7_u8
                );
            }
        }

        // if explore_till_beast is true and adventurer can still explore
        if explore_till_beast && adventurer.can_explore() {
            // Keep exploring
            _explore(
                ref self,
                ref adventurer,
                ref bag,
                ref explore_results,
                adventurer_id,
                level_seed,
                explore_till_beast
            );
        }
    }

    fn _alive_no_beast_no_upgrades(self: Adventurer) -> bool {
        self.health != 0 && self.beast_health == 0 && self.stat_upgrades_available == 0
    }

    /// @title Process Discovery
    /// @notice Processes the discovery for the adventurer and emits an event.
    /// @dev This function is called when the adventurer discovers something.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param entropy A u128 representing the entropy for the adventurer.
    fn _process_discovery(
        ref self: ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        adventurer_id: felt252,
        discovery_type_rnd: u8,
        amount_rnd1: u8,
        amount_rnd2: u8
    ) {
        // get discovery type
        let discovery_type = ImplAdventurer::get_discovery(
            adventurer.get_level(), discovery_type_rnd, amount_rnd1, amount_rnd2
        );

        // Grant adventurer XP to progress entropy
        let (previous_level, new_level) = adventurer
            .increase_adventurer_xp(XP_FOR_DISCOVERIES.into());

        // handle discovery type
        match discovery_type {
            DiscoveryType::Gold(amount) => {
                adventurer.increase_gold(amount);
                __event_DiscoveredGold(ref self, adventurer, adventurer_id, amount);
            },
            DiscoveryType::Health(amount) => {
                adventurer.increase_health(amount);
                __event_DiscoveredHealth(ref self, adventurer, adventurer_id, amount);
            },
            DiscoveryType::Loot(item_id) => {
                let (item_in_bag, _) = bag.contains(item_id);

                let slot_free = adventurer.equipment.is_slot_free_item_id(item_id);

                // if the bag is full and the slot is not free
                let inventory_full = bag.is_full() && slot_free == false;

                // if item is in adventurers bag, is equipped or inventory is full
                if item_in_bag || adventurer.equipment.is_equipped(item_id) || inventory_full {
                    // we replace item discovery with gold based on market value of the item
                    let mut amount = 0;
                    match ImplLoot::get_tier(item_id) {
                        Tier::None(()) => panic!("found invalid item"),
                        Tier::T1(()) => amount = 20,
                        Tier::T2(()) => amount = 16,
                        Tier::T3(()) => amount = 12,
                        Tier::T4(()) => amount = 8,
                        Tier::T5(()) => amount = 4,
                    }
                    adventurer.increase_gold(amount);
                    __event_DiscoveredGold(ref self, adventurer, adventurer_id, amount);
                    // if the item is not already owned or equipped and the adventurer has space for
                // it
                } else {
                    // no items will be dropped as part of discovery
                    let dropped_items = ArrayTrait::<u8>::new();
                    let mut equipped_items = ArrayTrait::<u8>::new();
                    let mut bagged_items = ArrayTrait::<u8>::new();

                    let item = ImplItem::new(item_id);
                    if slot_free {
                        // equip the item
                        adventurer.equipment.equip(item);
                        equipped_items.append(item.id);
                    } else {
                        // otherwise toss it in bag
                        bag.add_item(item);
                        bagged_items.append(item.id);
                    }
                    __event_DiscoveredLoot(ref self, adventurer, adventurer_id, item_id);
                    __event_EquipmentChanged(
                        ref self,
                        adventurer,
                        adventurer_id,
                        bag,
                        equipped_items,
                        bagged_items,
                        dropped_items,
                    );
                }
            }
        }

        // check for level up
        if (adventurer.stat_upgrades_available != 0) {
            // process level up
            _process_level_up(ref self, ref adventurer, adventurer_id, previous_level, new_level);
        }
    }

    /// @title Beast Encounter
    /// @notice Handles the encounter with a beast and returns the battle details.
    /// @dev This function is called when the adventurer encounters a beast.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param beast_seed A u32 representing the seed for the beast.
    /// @param beast_health_rnd A u32 representing the random health for the beast.
    /// @param beast_level_rnd A u32 representing the random level for the beast.
    /// @param beast_specials_rnd A u32 representing the random specials for the beast.
    /// @param ambush_rnd A u32 representing the random ambush for the beast.
    /// @param critical_hit_rnd A u32 representing the random critical hit for the beast.
    fn _beast_encounter(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        health_rnd: u16,
        level_rnd: u16,
        dmg_location_rnd: u8,
        crit_hit_rnd: u8,
        ambush_rnd: u8,
        specials1_rnd: u8,
        specials2_rnd: u8,
    ) {
        let adventurer_level = adventurer.get_level();

        let beast = ImplAdventurer::get_beast(
            adventurer.get_level(),
            adventurer.equipment.weapon.id,
            seed,
            health_rnd,
            level_rnd,
            specials1_rnd,
            specials2_rnd
        );

        // init beast health on adventurer
        // @dev: this is only info about beast that we store onchain
        adventurer.beast_health = beast.starting_health;

        // check if beast ambushed adventurer
        let is_ambush = ImplAdventurer::is_ambushed(
            adventurer_level, adventurer.stats.wisdom, ambush_rnd
        );

        // if adventurer was ambushed
        if (is_ambush) {
            // process beast attack
            let beast_battle_details = _beast_attack(
                ref self,
                ref adventurer,
                adventurer_id,
                beast,
                seed,
                crit_hit_rnd,
                dmg_location_rnd,
                is_ambush
            );
            __event_AmbushedByBeast(ref self, adventurer, adventurer_id, beast_battle_details);
            if (adventurer.health == 0) {
                _process_adventurer_death(
                    ref self, ref adventurer, adventurer_id, beast.id, 0, false
                );
                return;
            }
        } else {
            // Emit Discover Beast event
            __event_DiscoveredBeast(ref self, adventurer, adventurer_id, seed, beast);
        }
    }

    /// @title Obstacle Encounter
    /// @notice Handles the encounter with an obstacle and returns the battle details.
    /// @dev This function is called when the adventurer encounters an obstacle.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param rnd A u32 representing the entropy for the adventurer.
    fn _obstacle_encounter(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        level_rnd: u16,
        dmg_location_rnd: u8,
        crit_hit_rnd: u8,
        dodge_rnd: u8
    ) {
        // get adventurer's level
        let adventurer_level = adventurer.get_level();

        // get random obstacle
        let obstacle = ImplAdventurer::get_random_obstacle(adventurer_level, seed, level_rnd);

        // get a random attack location for the obstacle
        let damage_slot = ImplAdventurer::get_attack_location(dmg_location_rnd);

        // get armor at the location being attacked
        let armor = adventurer.equipment.get_item_at_slot(damage_slot);

        // get damage from obstalce
        let (combat_result, _) = adventurer.get_obstacle_damage(obstacle, armor, crit_hit_rnd);

        // pull damage taken out of combat result for easy access
        let damage_taken = combat_result.total_damage;

        // get base xp reward for obstacle
        let base_reward = obstacle.get_xp_reward(adventurer_level);

        // get item xp reward for obstacle
        let item_xp_reward = base_reward * ITEM_XP_MULTIPLIER_OBSTACLES.into();

        // create obstacle details for event
        let obstacle_details = ObstacleDetails {
            id: obstacle.id,
            level: obstacle.combat_spec.level,
            damage_taken,
            damage_location: ImplCombat::slot_to_u8(damage_slot),
            critical_hit: combat_result.critical_hit_bonus > 0,
            adventurer_xp_reward: base_reward,
            item_xp_reward
        };

        // attempt to dodge obstacle
        let dodged = ImplCombat::ability_based_avoid_threat(
            adventurer_level, adventurer.stats.intelligence, dodge_rnd
        );

        // if adventurer did not dodge obstacle
        if (!dodged) {
            // adventurer takes damage
            adventurer.decrease_health(damage_taken);

            // if adventurer died
            if (adventurer.health == 0) {
                // emit obstacle encounter event
                __event_ObstacleEncounter(
                    ref self, adventurer, adventurer_id, dodged, obstacle_details
                );
                // process death
                _process_adventurer_death(
                    ref self, ref adventurer, adventurer_id, 0, obstacle.id, false
                );
                // return without granting xp to adventurer or items
                return;
            }
        }

        // grant adventurer xp and get previous and new level
        let (previous_level, new_level) = adventurer.increase_adventurer_xp(base_reward);

        // grant items xp and get array of items that leveled up
        let items_leveled_up = _grant_xp_to_equipped_items(
            ref self, ref adventurer, adventurer_id, item_xp_reward
        );

        // emit obstacle encounter event after granting xp to adventurer and items
        __event_ObstacleEncounter(ref self, adventurer, adventurer_id, dodged, obstacle_details);

        // if items leveled up
        if items_leveled_up.len() != 0 {
            // emit item leveled up event
            __event_ItemsLeveledUp(ref self, adventurer, adventurer_id, items_leveled_up);
        }

        // if adventurer got new stat upgrades
        if (adventurer.stat_upgrades_available != 0) {
            // emit levled up event
            _process_level_up(ref self, ref adventurer, adventurer_id, previous_level, new_level);
        }
    }

    // @notice Grants XP to items currently equipped by an adventurer, and processes any level
    // ups.//
    // @dev This function does three main things:
    //   1. Iterates through each of the equipped items for the given adventurer.
    //   2. Increases the XP for the equipped item. If the item levels up, it processes the level up
    //   and updates the item.
    //   3. If any items have leveled up, emits an `ItemsLeveledUp` event.//
    // @param self The contract's state reference.
    // @param adventurer Reference to the adventurer's state.
    // @param adventurer_id Unique identifier for the adventurer.
    // @param xp_amount Amount of XP to grant to each equipped item.
    // @return Array of items that leveled up.
    fn _grant_xp_to_equipped_items(
        ref self: ContractState, ref adventurer: Adventurer, adventurer_id: felt252, xp_amount: u16,
    ) -> Array<ItemLeveledUp> {
        let mut items_leveled_up = ArrayTrait::<ItemLeveledUp>::new();
        let equipped_items = adventurer.get_equipped_items();
        let mut item_index: u32 = 0;
        loop {
            if item_index == equipped_items.len() {
                break;
            }
            // get item
            let item = *equipped_items.at(item_index);

            // get item slot
            let item_slot = ImplLoot::get_slot(item.id);

            // increase item xp and record previous and new level
            let (previous_level, new_level) = adventurer
                .equipment
                .increase_item_xp_at_slot(item_slot, xp_amount);

            // if item leveled up
            if new_level > previous_level {
                // process level up
                let updated_item = _process_item_level_up(
                    ref self,
                    ref adventurer,
                    adventurer_id,
                    adventurer.equipment.get_item_at_slot(item_slot),
                    previous_level,
                    new_level,
                );

                // add item to list of items that leveled up to be emitted in event
                items_leveled_up.append(updated_item);
            }

            item_index += 1;
        };

        items_leveled_up
    }

    /// @title Process Item Level Up
    /// @notice Processes the level up for an item and returns the updated item.
    /// @dev This function is called when an item levels up.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item A reference to the item.
    /// @param previous_level A u8 representing the previous level of the item.
    /// @param new_level A u8 representing the new level of the item.
    /// @return ItemLeveledUp The updated item.
    fn _process_item_level_up(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        item: Item,
        previous_level: u8,
        new_level: u8,
    ) -> ItemLeveledUp {
        // if item reached max greatness level
        if (new_level == ITEM_MAX_GREATNESS) {
            // adventurer receives a bonus stat upgrade point
            adventurer.increase_stat_upgrades_available(MAX_GREATNESS_STAT_BONUS);
        }

        // check if item unlocked specials as part of level up
        let (suffix_unlocked, prefixes_unlocked) = ImplAdventurer::unlocked_specials(
            previous_level, new_level
        );

        // get item specials seed
        let item_specials_seed = _get_item_specials_seed(@self, adventurer_id);
        let specials = if item_specials_seed != 0 {
            ImplLoot::get_specials(item.id, item.get_greatness(), item_specials_seed)
        } else {
            SpecialPowers { special1: 0, special2: 0, special3: 0 }
        };

        // if specials were unlocked
        if (suffix_unlocked || prefixes_unlocked) {
            // check if we already have the vrf seed for the item specials
            if item_specials_seed != 0 {
                // if suffix was unlocked, apply stat boosts for suffix special to adventurer
                if suffix_unlocked {
                    // apply stat boosts for suffix special to adventurer
                    adventurer.stats.apply_suffix_boost(specials.special1);
                    // apply health boost for any vitality gained (one time event)
                    adventurer.apply_health_boost_from_vitality_unlock(specials);
                }
            } else {
                // if the contract doesn't have an item specials seed from vrf yet
                // we need to request one but only once so we use a flag to ensure we only request
                // for first item
                if !adventurer.awaiting_item_specials {
                    adventurer.awaiting_item_specials = true;

                    _event_RequestedItemSpecialsSeed(ref self, adventurer_id);

                    if _network_supports_vrf() {
                        _request_randomness(
                            ref self, adventurer_id.try_into().unwrap(), adventurer_id, 1
                        );
                    } else {
                        // if we are running on a network that doesn't support vrf
                        // we generate a basic seed using item.xp + item.id
                        let item_specials_seed = item.xp + item.id.into();

                        // set the seed in the contract
                        _set_item_specials_seed(ref self, adventurer_id, item_specials_seed);

                        // get specials for the item
                        let specials = ImplLoot::get_specials(
                            item.id, item.get_greatness(), item_specials_seed
                        );

                        // if suffix was unlocked, apply stat boosts for suffix special to
                        // adventurer
                        if suffix_unlocked {
                            // apply stat boosts for suffix special to adventurer
                            adventurer.stats.apply_suffix_boost(specials.special1);
                            // apply health boost for any vitality gained (one time event)
                            adventurer.apply_health_boost_from_vitality_unlock(specials);
                        }
                    }
                }
            }
        }
        ItemLeveledUp {
            item_id: item.id,
            previous_level,
            new_level,
            suffix_unlocked,
            prefixes_unlocked,
            specials
        }
    }

    fn _network_supports_vrf() -> bool {
        let chain_id = get_tx_info().unbox().chain_id;
        chain_id == MAINNET_CHAIN_ID || chain_id == SEPOLIA_CHAIN_ID
    }

    fn _get_and_apply_item_specials(
        ref adventurer: Adventurer, ref specials: SpecialPowers, item: Item, item_specials_seed: u16
    ) {
        specials = ImplLoot::get_specials(item.id, item.get_greatness(), item_specials_seed);

        // apply the item stat boosts so that subsequent events include this information
        adventurer.stats.apply_suffix_boost(specials.special1);

        // check if the suffix provided a vitality boost
        let vitality_boost = ImplAdventurer::get_vitality_item_boost(specials.special1);
        if (vitality_boost != 0) {
            // if so, adventurer gets health
            let health_amount = vitality_boost.into() * VITALITY_INSTANT_HEALTH_BONUS.into();
            adventurer.increase_health(health_amount);
        }
    }

    /// @notice Executes an adventurer's attack on a beast and manages the consequences of the
    /// combat @dev This function covers the entire combat process between an adventurer and a
    /// beast, including generating randomness for combat, handling the aftermath of the attack, and
    /// any subsequent counter-attacks by the beast.
    /// @param self The current contract state
    /// @param adventurer The attacking adventurer
    /// @param weapon_combat_spec The combat specifications of the adventurer's weapon
    /// @param adventurer_id The unique identifier of the adventurer
    /// @param level_seed A random value tied to the adventurer to aid in determining certain random
    /// aspects of the combat @param beast The defending beast
    /// @param beast_seed The seed associated with the beast
    /// @param fight_to_the_death Flag to indicate whether the adventurer should continue attacking
    /// until either they or the beast is defeated
    fn _attack(
        ref self: ContractState,
        ref adventurer: Adventurer,
        weapon_combat_spec: CombatSpec,
        adventurer_id: felt252,
        level_seed: u64,
        beast: Beast,
        beast_seed: u32,
        fight_to_the_death: bool,
    ) {
        // get randomness for combat
        let (_, adventurer_crit_hit_rnd, beast_crit_hit_rnd, attack_location_rnd) =
            ImplAdventurer::get_battle_randomness(
            adventurer.xp, adventurer.battle_action_count, level_seed
        );

        // increment battle action count (ensures each battle action has unique randomness)
        adventurer.increment_battle_action_count();

        // attack beast and get combat result that provides damage breakdown
        let combat_result = adventurer.attack(weapon_combat_spec, beast, adventurer_crit_hit_rnd);

        // provide critical hit as a boolean for events
        let is_critical_hit = combat_result.critical_hit_bonus > 0;

        // if the damage dealt exceeds the beasts health
        if (combat_result.total_damage >= adventurer.beast_health) {
            // process beast death
            _process_beast_death(
                ref self,
                ref adventurer,
                adventurer_id,
                beast,
                beast_seed,
                combat_result.total_damage,
                is_critical_hit
            );
        } else {
            // if beast survived the attack, deduct damage dealt
            adventurer.beast_health -= combat_result.total_damage;

            // process beast counter attack
            let attacked_by_beast_details = _beast_attack(
                ref self,
                ref adventurer,
                adventurer_id,
                beast,
                beast_seed,
                beast_crit_hit_rnd,
                attack_location_rnd,
                false
            );

            // emit events
            __event_AttackedBeast(
                ref self,
                adventurer,
                adventurer_id,
                BattleDetails {
                    seed: beast_seed,
                    id: beast.id,
                    beast_specs: beast.combat_spec,
                    damage: combat_result.total_damage,
                    critical_hit: is_critical_hit,
                    location: ImplCombat::slot_to_u8(Slot::None(())),
                }
            );
            __event_AttackedByBeast(ref self, adventurer, adventurer_id, attacked_by_beast_details);

            // if adventurer is dead
            if (adventurer.health == 0) {
                _process_adventurer_death(
                    ref self, ref adventurer, adventurer_id, beast.id, 0, false
                );
                return;
            }

            // if the adventurer is still alive and fighting to the death
            if fight_to_the_death {
                // attack again
                _attack(
                    ref self,
                    ref adventurer,
                    weapon_combat_spec,
                    adventurer_id,
                    level_seed,
                    beast,
                    beast_seed,
                    true
                );
            }
        }
    }

    /// @title Beast Attack (Internal)
    /// @notice Handles attacks by a beast on an adventurer
    /// @dev This function determines a random attack location on the adventurer, retrieves armor
    /// and specials from that location, processes the beast attack, and deducts the damage from the
    /// adventurer's health.
    /// @param self The current contract state
    /// @param adventurer The adventurer being attacked
    /// @param adventurer_id The unique identifier of the adventurer
    /// @param beast The beast that is attacking
    /// @param beast_seed The seed associated with the beast
    /// @param critical_hit_rnd A random value used to determine whether a critical hit was made
    /// @return Returns a BattleDetails object containing details of the beast's attack, including
    /// the seed, beast ID, combat specifications of the beast, total damage dealt, whether a
    /// critical hit was made, and the location of the attack on the adventurer.
    fn _beast_attack(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        beast: Beast,
        beast_seed: u32,
        critical_hit_rnd: u8,
        attack_location_rnd: u8,
        is_ambush: bool
    ) -> BattleDetails {
        // beasts attack random location on adventurer
        let attack_location = ImplAdventurer::get_attack_location(attack_location_rnd);

        // get armor at attack location
        let armor = adventurer.equipment.get_item_at_slot(attack_location);

        // get armor specials
        let armor_specials = ImplLoot::get_specials(
            armor.id, armor.get_greatness(), _get_item_specials_seed(@self, adventurer_id)
        );

        // process beast attack
        let (combat_result, _jewlery_armor_bonus) = adventurer
            .defend(beast, armor, armor_specials, critical_hit_rnd, is_ambush);

        // deduct damage taken from adventurer's health
        adventurer.decrease_health(combat_result.total_damage);

        // return beast battle details
        BattleDetails {
            seed: beast_seed,
            id: beast.id,
            beast_specs: beast.combat_spec,
            damage: combat_result.total_damage,
            critical_hit: combat_result.critical_hit_bonus > 0,
            location: ImplCombat::slot_to_u8(attack_location),
        }
    }

    /// @title Flee
    /// @notice Handles an attempt by the adventurer to flee from a battle with a beast.
    /// @dev This function is called when the adventurer attempts to flee from a battle with a
    /// beast.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param level_seed A felt252 representing the entropy for the adventurer.
    /// @param beast_seed A u32 representing the seed for the beast.
    /// @param beast A reference to the beast that the adventurer is attempting to flee from.
    /// @param flee_to_the_death A bool representing whether to flee until death.
    fn _flee(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        level_seed: u64,
        beast_seed: u32,
        beast: Beast,
        flee_to_the_death: bool
    ) {
        // get randomness for flee and ambush
        let (flee_rnd, _, beast_crit_hit_rnd, attack_location_rnd) =
            ImplAdventurer::get_battle_randomness(
            adventurer.xp, adventurer.battle_action_count, level_seed
        );

        // increment battle action count (ensures each battle action has unique randomness)
        adventurer.increment_battle_action_count();

        // attempt to flee
        let fled = ImplBeast::attempt_flee(
            adventurer.get_level(), adventurer.stats.dexterity, flee_rnd
        );

        // if adventurer fled
        if (fled) {
            // set beast health to zero to denote adventurer is no longer in battle
            adventurer.beast_health = 0;

            // set battle action count to zero to reset battle randomness
            adventurer.battle_action_count = 0;

            // increment adventurer xp by one to change adventurer entropy state
            let (previous_level, new_level) = adventurer.increase_adventurer_xp(1);

            // emit flee attempt event
            __event_FleeSucceeded(ref self, adventurer, adventurer_id, beast_seed, beast);

            // check for adventurer level up
            if (adventurer.stat_upgrades_available != 0) {
                _process_level_up(
                    ref self, ref adventurer, adventurer_id, previous_level, new_level
                );
            }
        } else {
            // if the flee attempt failed, beast counter attacks
            let beast_battle_details = _beast_attack(
                ref self,
                ref adventurer,
                adventurer_id,
                beast,
                beast_seed,
                beast_crit_hit_rnd,
                attack_location_rnd,
                false
            );

            __event_FleeFailed(ref self, adventurer, adventurer_id, beast_seed, beast);
            __event_AttackedByBeast(ref self, adventurer, adventurer_id, beast_battle_details);

            // if player is still alive and elected to flee till death
            if (flee_to_the_death && adventurer.health != 0) {
                // reattempt flee
                _flee(ref self, ref adventurer, adventurer_id, level_seed, beast_seed, beast, true);
            }
        }
    }

    /// @title Equip Item
    /// @notice Equips a specific item to the adventurer, and if there's an item already equipped in
    /// that slot, it's moved to the bag.
    /// @dev This function is called when an item is equipped to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item The primitive item to be equipped.
    /// @return The ID of the item that has been unequipped.
    fn _equip_item(
        self: @ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        adventurer_id: felt252,
        item: Item
    ) -> u8 {
        // get the item currently equipped to the slot the item is being equipped to
        let unequipping_item = adventurer.equipment.get_item_at_slot(ImplLoot::get_slot(item.id));

        // if the item exists
        if unequipping_item.id != 0 {
            // put it into the adventurer's bag
            bag.add_item(unequipping_item);

            // if the item was providing a stat boosts, remove it
            if unequipping_item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
                _remove_item_stat_boost(self, ref adventurer, adventurer_id, unequipping_item);
            }
        }

        // equip item
        adventurer.equipment.equip(item);

        // if item being equipped has stat boosts unlocked, apply it to adventurer
        if item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
            _apply_item_stat_boost(self, ref adventurer, adventurer_id, item);
        }

        // return the item being unequipped for events
        unequipping_item.id
    }

    /// @title Equip Items
    /// @notice Equips items to the adventurer and returns the items that were unequipped as a
    /// result.
    /// @dev This function is called when items are equipped to the adventurer.
    /// @param contract_state A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param items_to_equip An array of u8 representing the items to be equipped.
    /// @param is_newly_purchased A bool representing whether the items are newly purchased.
    /// @return An array of u8 representing the items that were unequipped as a result of equipping
    /// the items.
    fn _equip_items(
        contract_state: @ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        adventurer_id: felt252,
        items_to_equip: Array<u8>,
        is_newly_purchased: bool
    ) -> Array<u8> {
        // mutable array from returning items that were unequipped as a result of equipping the
        // items
        let mut unequipped_items = ArrayTrait::<u8>::new();

        // get a clone of our items to equip to keep ownership for event
        let _equipped_items = items_to_equip.clone();

        // for each item we need to equip
        let mut i: u32 = 0;
        loop {
            if i == items_to_equip.len() {
                break ();
            }

            // get the item id
            let item_id = *items_to_equip.at(i);

            // assume we won't need to unequip an item to equip new one
            let mut unequipped_item_id: u8 = 0;

            // if item is newly purchased
            if is_newly_purchased {
                // assert adventurer does not already own the item
                _assert_item_not_owned(adventurer, bag, item_id.clone());

                // create new item, equip it, and record if we need unequipped an item
                let mut new_item = ImplItem::new(item_id);
                unequipped_item_id =
                    _equip_item(contract_state, ref adventurer, ref bag, adventurer_id, new_item);
            } else {
                // otherwise item is being equipped from bag
                // so remove it from bag, equip it, and record if we need to unequip an item
                unequipped_item_id =
                    _equip_item(
                        contract_state,
                        ref adventurer,
                        ref bag,
                        adventurer_id,
                        bag.remove_item(item_id)
                    );
            }

            // if an item was unequipped
            if unequipped_item_id != 0 {
                // add it to our return array so we can emit these in events
                unequipped_items.append(unequipped_item_id);
            }

            i += 1;
        };

        unequipped_items
    }

    /// @title Drop Items
    /// @notice Drops multiple items from the adventurer's possessions, either from equipment or
    /// bag.
    /// @dev This function is called when items are dropped from the adventurer's possessions.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param items An array of u8 representing the items to be dropped.
    /// @return A tuple containing two boolean values. The first indicates if the adventurer was
    /// mutated, the second indicates if the bag was mutated.
    fn _drop(
        ref self: ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        adventurer_id: felt252,
        items: Array<u8>,
    ) {
        // for each item
        let mut i: u32 = 0;
        loop {
            if i == items.len() {
                break ();
            }

            // init a blank item to use for dropped item storage
            let mut item = ImplItem::new(0);

            // get item id
            let item_id = *items.at(i);

            // if item is equipped
            if adventurer.equipment.is_equipped(item_id) {
                // get it from adventurer equipment
                item = adventurer.equipment.get_item(item_id);

                // if the item was providing a stat boosts
                if item.get_greatness() >= SUFFIX_UNLOCK_GREATNESS {
                    // remove it
                    _remove_item_stat_boost(@self, ref adventurer, adventurer_id, item);
                }

                // drop the item
                adventurer.equipment.drop(item_id);

                // set adventurer to mutated
                adventurer.mutated = true;
            } else {
                // if item is not equipped, it must be in the bag
                // but we double check and panic just in case
                let (item_in_bag, _) = bag.contains(item_id);
                if item_in_bag {
                    // get item from the bag
                    item = bag.get_item(item_id);

                    // remove item from the bag (sets mutated to true)
                    bag.remove_item(item_id);
                } else {
                    panic_with_felt252('Item not owned by adventurer');
                }
            }

            // add item to our adventurer dropped item storage
            self._adventurer_dropped_items.append().write(item);

            i += 1;
        };
    }

    /// @title Buy Items
    /// @notice Facilitates the purchase of multiple items and returns the items that were
    /// purchased, equipped, and unequipped.
    /// @dev This function is called when the adventurer purchases items.
    /// @param contract_state A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param stat_upgrades_available A u8 representing the number of stat points available to the
    /// adventurer.
    /// @param items_to_purchase An array of ItemPurchase representing the items to be purchased.
    /// @return A tuple containing three arrays: the first contains the items purchased, the second
    /// contains the items that were equipped as part of the purchase, and the third contains the
    /// items that were unequipped as a result of equipping the newly purchased items.
    fn _buy_items(
        self: @ContractState,
        ref adventurer: Adventurer,
        ref bag: Bag,
        adventurer_id: felt252,
        stat_upgrades_available: u8,
        items_to_purchase: Array<ItemPurchase>,
    ) -> (Array<LootWithPrice>, Array<u8>, Array<u8>) {
        // get adventurer entropy
        let market_inventory = _get_market(self, adventurer_id, stat_upgrades_available);

        // mutable array for returning items that need to be equipped as part of this purchase
        let mut unequipped_items = ArrayTrait::<u8>::new();
        let mut items_to_equip = ArrayTrait::<u8>::new();

        // iterate over item ids to purchase and store results in purchases array
        let mut purchases = ArrayTrait::<LootWithPrice>::new();
        let mut item_number: u32 = 0;
        loop {
            if item_number == items_to_purchase.len() {
                break ();
            }

            // get the item
            let item = *items_to_purchase.at(item_number);

            // get a mutable reference to the inventory
            let mut inventory = market_inventory.span();

            // assert item is available on market
            _assert_item_is_available(ref inventory, item.item_id);

            // buy it and store result in our purchases array for event
            purchases.append(_buy_item(ref adventurer, ref bag, item.item_id));

            // if item is being equipped as part of the purchase
            if item.equip {
                // add it to our array of items to equip
                items_to_equip.append(item.item_id);
            } else {
                // if it's not being equipped, just add it to bag
                bag.add_new_item(adventurer, item.item_id)
            }

            // increment counter
            item_number += 1;
        };

        // if we have items to equip as part of the purchase
        if (items_to_equip.len() != 0) {
            // equip them and record the items that were unequipped
            unequipped_items =
                _equip_items(
                    self, ref adventurer, ref bag, adventurer_id, items_to_equip.clone(), true
                );
        }

        (purchases, items_to_equip, unequipped_items)
    }

    /// @title Buy Potions
    /// @notice Processes the purchase of potions for the adventurer and emits an event.
    /// @dev This function is called when the adventurer purchases potions.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param quantity A u8 representing the number of potions to buy.
    fn _buy_potions(
        ref self: ContractState, ref adventurer: Adventurer, adventurer_id: felt252, quantity: u8
    ) {
        let cost = adventurer.charisma_adjusted_potion_price() * quantity.into();
        let health = POTION_HEALTH_AMOUNT.into() * quantity.into();

        // assert adventurer has enough gold to buy the potions
        _assert_has_enough_gold(adventurer, cost);

        // assert adventurer is not buying more health than they can use
        _assert_not_buying_excess_health(adventurer, health);

        // deduct cost of potions from adventurers gold balance
        adventurer.deduct_gold(cost);

        // add health to adventurer
        adventurer.increase_health(health);

        // emit purchased potions event
        __event_PurchasedPotions(ref self, adventurer, adventurer_id, quantity, cost, health);
    }

    /// @title Buy Item
    /// @notice Buys an item with the item price adjusted for adventurer's charisma.
    /// @dev This function is called when the adventurer buys an item.
    /// @param adventurer A reference to the adventurer.
    /// @param bag A reference to the bag.
    /// @param item_id A u8 representing the ID of the item to be purchased.
    /// @return The item that was purchased and its price.
    fn _buy_item(ref adventurer: Adventurer, ref bag: Bag, item_id: u8) -> LootWithPrice {
        // create an immutable copy of our adventurer to use for validation
        let immutable_adventurer = adventurer;

        // assert adventurer does not already own the item
        _assert_item_not_owned(immutable_adventurer, bag, item_id);

        // assert item is valid
        _assert_valid_item_id(item_id);

        // get item from item id
        let item = ImplLoot::get_item(item_id);

        // get item price
        let base_item_price = ImplMarket::get_price(item.tier);

        // get item price with charisma discount
        let charisma_adjusted_price = adventurer
            .stats
            .charisma_adjusted_item_price(base_item_price);

        // check adventurer has enough gold to buy the item
        _assert_has_enough_gold(immutable_adventurer, charisma_adjusted_price);

        // deduct charisma adjusted cost of item from adventurer's gold balance
        adventurer.deduct_gold(charisma_adjusted_price);

        // return item with price
        LootWithPrice { item: item, price: charisma_adjusted_price }
    }

    // ------------------------------------------ //
    // ------------ Helper Functions ------------ //
    // ------------------------------------------ //

    /// @title Load Player Assets
    /// @notice Loads the player's assets and returns the adventurer, level_seed, and bag.
    /// @dev This function is called when the player's assets are loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return A tuple containing the adventurer, level_seed, and bag.
    fn _load_player_assets(self: @ContractState, adventurer_id: felt252) -> (Adventurer, u64, Bag) {
        let adventurer = _load_adventurer(self, adventurer_id);
        let level_seed = _get_level_seed(self, adventurer_id);
        let bag = _load_bag(self, adventurer_id);
        (adventurer, level_seed, bag)
    }

    /// @title Load Adventurer
    /// @notice Loads the adventurer and returns the adventurer.
    /// @dev This function is called when the adventurer is loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _load_adventurer(self: @ContractState, adventurer_id: felt252) -> Adventurer {
        let mut adventurer = self._adventurer.read(adventurer_id);
        _apply_equipment_stat_boosts(self, ref adventurer, adventurer_id);
        _apply_luck(self, ref adventurer, adventurer_id);
        adventurer
    }

    /// @title Load Adventurer No Boosts
    /// @notice Loads the adventurer and returns the adventurer without boosts.
    /// @dev This function is called when the adventurer is loaded without boosts.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _load_adventurer_no_boosts(self: @ContractState, adventurer_id: felt252) -> Adventurer {
        self._adventurer.read(adventurer_id)
    }

    /// @title Load Adventurer Name
    /// @notice Loads the adventurer name and returns the adventurer name.
    /// @dev This function is called when the adventurer name is loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer name.
    fn _load_adventurer_name(self: @ContractState, adventurer_id: felt252) -> felt252 {
        self._adventurer_name.read(adventurer_id)
    }

    /// @title Save Adventurer
    /// @notice Saves the adventurer and returns the adventurer.
    /// @dev This function is called when the adventurer is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _save_adventurer(
        ref self: ContractState, ref adventurer: Adventurer, adventurer_id: felt252,
    ) {
        _remove_equipment_stat_boosts(@self, ref adventurer, adventurer_id);
        self._adventurer.write(adventurer_id, adventurer);
    }

    /// @title Save Adventurer No Boosts
    /// @notice Saves the adventurer without boosts and returns the adventurer.
    /// @dev This function is called when the adventurer is saved without boosts.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer.
    fn _save_adventurer_no_boosts(
        ref self: ContractState, adventurer: Adventurer, adventurer_id: felt252,
    ) {
        self._adventurer.write(adventurer_id, adventurer);
    }

    /// @title Apply Luck
    /// @notice Applies the adventurer's luck to the adventurer.
    /// @dev This function is called when the adventurer's luck is applied.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _apply_luck(self: @ContractState, ref adventurer: Adventurer, adventurer_id: felt252) {
        let bag = _load_bag(self, adventurer_id);
        adventurer.set_luck(bag);
    }

    /// @title Load Bag
    /// @notice Loads the bag and returns the bag.
    /// @dev This function is called when the bag is loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The bag.
    fn _load_bag(self: @ContractState, adventurer_id: felt252) -> Bag {
        self._bag.read(adventurer_id)
    }

    /// @title Save Bag
    /// @notice Saves the bag and returns the bag.
    /// @dev This function is called when the bag is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param bag A reference to the bag.
    fn _save_bag(ref self: ContractState, adventurer_id: felt252, bag: Bag) {
        self._bag.write(adventurer_id, bag);
    }

    /// @title Load Adventurer Metadata
    /// @notice Loads the adventurer metadata and returns the adventurer metadata.
    /// @dev This function is called when the adventurer metadata is loaded.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return The adventurer metadata.
    fn _load_adventurer_metadata(
        self: @ContractState, adventurer_id: felt252
    ) -> AdventurerMetadata {
        self._adventurer_meta.read(adventurer_id)
    }

    fn _get_item_specials_seed(self: @ContractState, adventurer_id: felt252) -> u16 {
        _load_adventurer_metadata(self, adventurer_id).item_specials_seed
    }

    fn _set_item_specials_seed(
        ref self: ContractState, adventurer_id: felt252, item_specials_seed: u16
    ) {
        let mut adventurer_meta = _load_adventurer_metadata(@self, adventurer_id);
        adventurer_meta.item_specials_seed = item_specials_seed;
        _save_adventurer_metadata(ref self, adventurer_id, adventurer_meta);
    }

    /// @title Apply Item Stat Boost
    /// @notice Applies the item stat boost to the adventurer.
    /// @dev This function is called when the item stat boost is applied to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item A reference to the item.
    fn _apply_item_stat_boost(
        self: @ContractState, ref adventurer: Adventurer, adventurer_id: felt252, item: Item
    ) {
        let item_specials_seed = _get_item_specials_seed(self, adventurer_id);
        let item_suffix = ImplLoot::get_suffix(item.id, item_specials_seed);
        adventurer.stats.apply_suffix_boost(item_suffix);
    }

    /// @title Remove Item Stat Boost
    /// @notice Removes the item stat boost from the adventurer.
    /// @dev This function is called when the item stat boost is removed from the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param item A reference to the item.
    fn _remove_item_stat_boost(
        self: @ContractState, ref adventurer: Adventurer, adventurer_id: felt252, item: Item
    ) {
        let item_suffix = ImplLoot::get_suffix(
            item.id, _get_item_specials_seed(self, adventurer_id)
        );
        adventurer.stats.remove_suffix_boost(item_suffix);

        // if the adventurer's health is now above the max health due to a change in Vitality
        let max_health = adventurer.stats.get_max_health();
        if adventurer.health > max_health {
            // lower adventurer's health to max health
            adventurer.health = max_health;
        }
    }

    /// @title Apply Equipment Stat Boosts
    /// @notice Applies the equipment stat boosts to the adventurer.
    /// @dev This function is called when the equipment stat boosts are applied to the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _apply_equipment_stat_boosts(
        self: @ContractState, ref adventurer: Adventurer, adventurer_id: felt252
    ) {
        if adventurer.equipment.has_specials() {
            let item_specials_seed = _get_item_specials_seed(self, adventurer_id);
            let item_stat_boosts = adventurer.equipment.get_stat_boosts(item_specials_seed);
            adventurer.stats.apply_stats(item_stat_boosts);
        }
    }

    /// @title Remove Equipment Stat Boosts
    /// @notice Removes the equipment stat boosts from the adventurer.
    /// @dev This function is called when the equipment stat boosts are removed from the adventurer.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    fn _remove_equipment_stat_boosts(
        self: @ContractState, ref adventurer: Adventurer, adventurer_id: felt252
    ) {
        let item_specials_seed = _get_item_specials_seed(self, adventurer_id);
        if adventurer.equipment.has_specials() && item_specials_seed != 0 {
            let item_stat_boosts = adventurer.equipment.get_stat_boosts(item_specials_seed);
            adventurer.stats.remove_stats(item_stat_boosts);
        }
    }

    /// @title Save Adventurer Metadata
    /// @notice Saves the adventurer metadata and returns the adventurer metadata.
    /// @dev This function is called when the adventurer metadata is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param adventurer_meta A reference to the adventurer metadata.
    fn _save_adventurer_metadata(
        ref self: ContractState, adventurer_id: felt252, adventurer_meta: AdventurerMetadata
    ) {
        self._adventurer_meta.write(adventurer_id, adventurer_meta);
    }


    /// @title Save Adventurer Name
    /// @notice Saves the adventurer name and returns the adventurer name.
    /// @dev This function is called when the adventurer name is saved.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param name A felt252 representing the name of the adventurer.
    fn _save_adventurer_name(ref self: ContractState, adventurer_id: felt252, name: felt252) {
        self._adventurer_name.write(adventurer_id, name);
    }

    /// @title Process Level Up
    /// @notice Processes the level up event and returns the adventurer.
    /// @dev This function is called when the adventurer levels up.
    /// @param self A reference to the ContractState object.
    /// @param adventurer A reference to the adventurer.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param previous_level A u8 representing the previous level of the adventurer.
    /// @param new_level A u8 representing the new level of the adventurer.
    fn _process_level_up(
        ref self: ContractState,
        ref adventurer: Adventurer,
        adventurer_id: felt252,
        previous_level: u8,
        new_level: u8,
    ) {
        let current_level_seed = _get_level_seed(@self, adventurer_id);

        // if adventurer is leveling up from the starter beast
        if (previous_level == 1) {
            // emit leveled up event
            __event_AdventurerLeveledUp(
                ref self, adventurer, adventurer_id, previous_level, new_level
            );

            // if the network we're running on supports vrf
            if _network_supports_vrf() {
                // check to see if we have vrf seed for the next level
                if (current_level_seed != 0) {
                    // process initial entropy which will reveal starting stats and emit starting
                    // market
                    reveal_starting_stats(ref adventurer, adventurer_id, current_level_seed);
                    // emit UpgradesAvailable event
                    __event_UpgradesAvailable(ref self, adventurer, adventurer_id);
                } else {
                    // if we're leveling up from the starter beast and we don't have starting
                    // entropy yet it may be because we didn't request it due to the player setting
                    // the delay_stat_reveal option
                    let delay_stat_reveal = _load_adventurer_metadata(@self, adventurer_id)
                        .delay_stat_reveal;
                    if delay_stat_reveal {
                        // if so, request vrf
                        _request_randomness(
                            ref self, adventurer_id.try_into().unwrap(), adventurer_id, 0
                        );
                    }
                }
            } else {
                // generate local randomness instead of requesting vrf
                process_new_level_seed(
                    ref self,
                    starknet::get_contract_address(),
                    ref adventurer,
                    adventurer_id,
                    ImplAdventurer::get_simple_entropy(adventurer.xp, adventurer_id),
                    0
                );
            }
        } else if (new_level > previous_level) {
            // if this is any level up beyond the starter beast
            if _network_supports_vrf() {
                // zero out level seed to freeze game state till vrf comes back
                _set_level_seed(ref self, adventurer_id, 0);

                // request new entropy
                _request_randomness(ref self, current_level_seed, adventurer_id, 0);

                // emit RequestedLevelSeed event to let clients know the contract is fetching new
                // entropy
                __event_RequestedLevelSeed(ref self, adventurer_id, current_level_seed);
            } else {
                // if contract is running on katana, we don't do full vrf, and instead use basic
                // entropy which is hash of adventurer id and xp
                process_new_level_seed(
                    ref self,
                    starknet::get_contract_address(),
                    ref adventurer,
                    adventurer_id,
                    ImplAdventurer::get_simple_entropy(adventurer.xp, adventurer_id),
                    0
                );
            }

            // emit the leveled up event
            __event_AdventurerLeveledUp(
                ref self, adventurer, adventurer_id, previous_level, new_level
            );
        }
    }

    fn _assert_ownership(self: @ContractState, adventurer_id: felt252) {
        assert(
            self.erc721.ERC721_owners.read(adventurer_id.into()) == get_caller_address(),
            messages::NOT_OWNER
        );
    }
    fn _assert_in_battle(adventurer: Adventurer) {
        assert(adventurer.beast_health != 0, messages::NOT_IN_BATTLE);
    }
    fn _assert_dexterity_not_zero(adventurer: Adventurer) {
        assert(adventurer.stats.dexterity != 0, messages::ZERO_DEXTERITY);
    }
    fn _assert_not_in_battle(adventurer: Adventurer) {
        assert(adventurer.beast_health == 0, messages::ACTION_NOT_ALLOWED_DURING_BATTLE);
    }
    fn _assert_upgrades_available(stat_upgrades_available: u8) {
        assert(stat_upgrades_available != 0, messages::MARKET_CLOSED);
    }
    fn _assert_item_not_owned(adventurer: Adventurer, bag: Bag, item_id: u8) {
        let (item_in_bag, _) = bag.contains(item_id);
        assert(
            adventurer.equipment.is_equipped(item_id) == false && item_in_bag == false,
            messages::ITEM_ALREADY_OWNED
        );
    }
    fn _assert_valid_item_id(item_id: u8) {
        assert(item_id > 0 && item_id <= 101, messages::INVALID_ITEM_ID);
    }
    fn _assert_item_is_available(ref inventory: Span<u8>, item_id: u8) {
        assert(
            ImplMarket::is_item_available(ref inventory, item_id), messages::ITEM_DOES_NOT_EXIST
        );
    }
    fn _assert_not_starter_beast(adventurer: Adventurer, message: felt252) {
        assert(adventurer.get_level() > 1, message);
    }

    fn _assert_no_stat_upgrades_available(adventurer: Adventurer) {
        assert(adventurer.stat_upgrades_available == 0, messages::STAT_UPGRADES_AVAILABLE);
    }
    fn _assert_not_dead(self: Adventurer) {
        assert(self.health != 0, messages::DEAD_ADVENTURER);
    }
    fn _assert_is_dead(self: Adventurer) {
        assert(self.health == 0, messages::ADVENTURER_IS_ALIVE);
    }

    fn _is_genesis_adventurer(adventurer_id: felt252) -> bool {
        adventurer_id == 1 || adventurer_id == 2 || adventurer_id == 3
    }
    fn _is_expired(self: @ContractState, adventurer_id: felt252,) -> bool {
        if _is_genesis_adventurer(adventurer_id) {
            false
        } else {
            let current_time = get_block_timestamp();
            let birth_date = _load_adventurer_metadata(self, adventurer_id).birth_date;
            let expiry_time = birth_date + (GAME_EXPIRY_DAYS.into() * SECONDS_IN_DAY.into());
            current_time > expiry_time
        }
    }
    fn _assert_valid_starter_weapon(starting_weapon: u8) {
        assert(
            ImplLoot::is_starting_weapon(starting_weapon) == true, messages::INVALID_STARTING_WEAPON
        );
    }
    fn _assert_zero_luck(stats: Stats) {
        assert(stats.luck == 0, messages::NON_ZERO_STARTING_LUCK);
    }
    fn _assert_has_enough_gold(adventurer: Adventurer, cost: u16) {
        assert(adventurer.gold >= cost, messages::NOT_ENOUGH_GOLD);
    }
    fn _assert_not_buying_excess_health(adventurer: Adventurer, purchased_health: u16) {
        let adventurer_health_after_potions = adventurer.health + purchased_health;
        // assert adventurer is not buying more health than needed
        assert(
            adventurer_health_after_potions < adventurer.stats.get_max_health()
                + POTION_HEALTH_AMOUNT.into(),
            messages::HEALTH_FULL
        );
    }

    fn _assert_stat_balance(stat_upgrades: Stats, stat_upgrades_available: u8) {
        let stat_upgrade_count = stat_upgrades.strength
            + stat_upgrades.dexterity
            + stat_upgrades.vitality
            + stat_upgrades.intelligence
            + stat_upgrades.wisdom
            + stat_upgrades.charisma;

        if stat_upgrades_available < stat_upgrade_count {
            panic_with_felt252(messages::INSUFFICIENT_STAT_UPGRADES);
        } else if stat_upgrades_available > stat_upgrade_count {
            panic_with_felt252(messages::MUST_USE_ALL_STATS);
        }
    }
    fn _assert_valid_stat_selection(adventurer: Adventurer, stat_upgrades: Stats) {
        _assert_upgrades_available(adventurer.stat_upgrades_available);
        _assert_stat_balance(stat_upgrades, adventurer.stat_upgrades_available);
        _assert_zero_luck(stat_upgrades);
    }

    fn _assert_entropy_set(self: @ContractState, adventurer_id: felt252) {
        let level_seed = _get_level_seed(self, adventurer_id);
        assert(level_seed != 0, messages::LEVEL_SEED_NOT_SET);
    }

    fn _assert_not_awaiting_item_specials(
        self: @ContractState, adventurer_id: felt252, adventurer: Adventurer, bag: Bag
    ) {
        // if any of the adventurer's items have specials unlocked
        if adventurer.equipment.has_specials() || bag.has_specials() {
            // assert we have the item specials seed
            let item_specials_seed = _get_item_specials_seed(self, adventurer_id);
            assert(item_specials_seed != 0, messages::WAITING_FOR_ITEM_SPECIALS);
        }
    }

    fn _assert_launch_tournament_is_active(self: @ContractState) {
        assert(_is_launch_tournament_active(self), messages::LAUNCH_TOURNAMENT_ENDED);
    }

    fn _assert_launch_tournament_has_ended(self: @ContractState) {
        assert(!_is_launch_tournament_active(self), messages::TOURNAMENT_STILL_ACTIVE);
    }

    fn _assert_game_is_live(self: @ContractState) {
        assert(_is_game_live(self), messages::GAME_NOT_LIVE);
    }

    fn _is_game_live(self: @ContractState) -> bool {
        let current_timestamp = starknet::get_block_info().unbox().block_timestamp;
        // get genesis timestamp
        let genesis_timestamp = self._genesis_timestamp.read();
        // get start delay
        let start_delay = self._start_delay_seconds.read();
        // get game start time
        let game_start_time = genesis_timestamp + start_delay;
        // assert current timestamp is greater than or equal to game start time
        current_timestamp >= game_start_time
    }

    fn _launch_tournament_end_time(self: @ContractState) -> u64 {
        let genesis_timestamp = self._genesis_timestamp.read();
        let start_delay = self._start_delay_seconds.read();
        let duration = self._launch_tournament_duration_seconds.read();
        genesis_timestamp + duration + start_delay
    }

    fn _is_launch_tournament_active(self: @ContractState) -> bool {
        let current_timestamp = starknet::get_block_info().unbox().block_timestamp;
        let launch_tournament_end_time = _launch_tournament_end_time(self);
        current_timestamp <= launch_tournament_end_time
    }

    fn _initialize_launch_tournament(
        ref self: ContractState, qualifying_collections: Span<LaunchTournamentCollections>
    ) {
        let mut collection_index = 0;

        // iterate over qualifying collections
        loop {
            if collection_index >= qualifying_collections.len() {
                break;
            }
            let qualifying_collection = *qualifying_collections.at(collection_index);

            // append qualifying collection to vector storage so we can easily iterate over them
            self
                ._launch_tournament_collections
                .append()
                .write(qualifying_collection.collection_address);

            // initialize qualifying collection scores to 1 to distinguish from ineligible
            // collections
            self._launch_tournament_scores.write(qualifying_collection.collection_address, 1);

            // store number of games allowed per collection
            self
                ._launch_tournament_games_per_claim
                .write(
                    qualifying_collection.collection_address, qualifying_collection.games_per_token
                );

            collection_index += 1;
        }
    }

    fn _is_qualifying_collection(
        self: @ContractState, nft_collection_address: ContractAddress
    ) -> bool {
        self._launch_tournament_scores.read(nft_collection_address) != 0
    }

    fn _assert_is_qualifying_nft(self: @ContractState, nft_collection_address: ContractAddress) {
        assert(
            _is_qualifying_collection(self, nft_collection_address),
            messages::COLLECTION_NOT_ELIGIBLE
        );
    }

    fn _assert_nft_ownership(
        self: @ContractState,
        nft_collection_address: ContractAddress,
        token_id: u128,
        caller: ContractAddress
    ) {
        let erc721_dispatcher = IERC721Dispatcher { contract_address: nft_collection_address };
        let token_owner = erc721_dispatcher.owner_of(token_id.into());
        assert(caller == token_owner, messages::NOT_TOKEN_OWNER);
    }

    fn _get_token_hash(
        self: @ContractState, collection_address: ContractAddress, token_id: u128
    ) -> felt252 {
        let mut hash_span = ArrayTrait::<felt252>::new();
        hash_span.append(collection_address.into());
        hash_span.append(token_id.into());
        poseidon_hash_span(hash_span.span())
    }

    fn _get_launch_tournament_winner(self: @ContractState) -> ContractAddress {
        self._launch_tournament_champions_dispatcher.read().contract_address
    }

    fn _assert_token_not_claimed(self: @ContractState, token_hash: felt252) {
        let token_hashed = self._launch_tournament_claimed_games.read(token_hash);
        assert(!token_hashed, messages::TOKEN_ALREADY_REGISTERED);
    }

    fn _assert_participated_in_tournament(self: @ContractState, token_hash: felt252) {
        let token_hash_exists = self._launch_tournament_claimed_games.read(token_hash);
        assert(token_hash_exists, messages::NOT_PARTICIPATED_IN_TOURNAMENT);
    }

    fn _get_market(
        self: @ContractState, adventurer_id: felt252, stat_upgrades_available: u8
    ) -> Array<u8> {
        let market_seed = _get_level_seed(self, adventurer_id);
        assert(market_seed != 0, messages::LEVEL_SEED_NOT_SET);

        let market_size = ImplMarket::get_market_size(stat_upgrades_available);
        ImplMarket::get_available_items(market_seed, market_size)
    }

    fn _get_potion_price(self: @ContractState, adventurer_id: felt252) -> u16 {
        _load_adventurer(self, adventurer_id).charisma_adjusted_potion_price()
    }

    fn _get_item_price(self: @ContractState, adventurer_id: felt252, item_id: u8) -> u16 {
        let base_item_price = ImplMarket::get_price(ImplLoot::get_tier(item_id));
        _load_adventurer(self, adventurer_id).stats.charisma_adjusted_item_price(base_item_price)
    }

    fn _get_attacking_beast(self: @ContractState, adventurer_id: felt252) -> Beast {
        // get adventurer
        let adventurer = _load_adventurer_no_boosts(self, adventurer_id);

        // assert adventurer is in battle
        assert(adventurer.beast_health != 0, messages::NOT_IN_BATTLE);

        if adventurer.get_level() > 1 {
            // get adventurer entropy
            let level_seed = _get_level_seed(self, adventurer_id);

            // generate xp based randomness seeds
            let (
                beast_seed,
                _,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd,
                _,
                _
            ) =
                ImplAdventurer::get_randomness(
                adventurer.xp, level_seed
            );

            // get beast based on entropy seeds
            ImplAdventurer::get_beast(
                adventurer.get_level(),
                adventurer.equipment.weapon.id,
                beast_seed,
                beast_health_rnd,
                beast_level_rnd,
                beast_specials1_rnd,
                beast_specials2_rnd
            )
        } else {
            let level_seed_u256: u256 = adventurer_id.try_into().unwrap();
            let beast_seed = (level_seed_u256 % TWO_POW_32.into()).try_into().unwrap();
            // generate starter beast which will have weak armor against the adventurers starter
            // weapon
            ImplBeast::get_starter_beast(
                ImplLoot::get_type(adventurer.equipment.weapon.id), beast_seed
            )
        }
    }

    fn _get_level_seed(self: @ContractState, adventurer_id: felt252) -> u64 {
        _load_adventurer_metadata(self, adventurer_id).level_seed
    }

    fn _is_top_score(self: @ContractState, score: u16) -> bool {
        if score > self._leaderboard.read().third.xp {
            true
        } else {
            false
        }
    }

    fn _get_owner(self: @ContractState, adventurer_id: felt252) -> ContractAddress {
        self.erc721.ERC721_owners.read(adventurer_id.into())
    }

    /// @title Get Delegate or Owner
    /// @notice Gets the delegate account address if the owner implements the controller delegate
    /// account interface.
    /// @dev This function is called when the delegate account address is needed.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @return A ContractAddress representing the delegate account address or the owner address.
    fn _get_delegate_or_owner(self: @ContractState, adventurer_id: felt252) -> ContractAddress {
        // get the nft owner address
        let owner_address = _get_owner(self, adventurer_id);

        // check if the owner account implements the controller delegate account interface
        let src5_dispatcher = ISRC5Dispatcher { contract_address: owner_address };
        if src5_dispatcher.supports_interface(CONTROLLER_DELEGATE_ACCOUNT_INTERFACE_ID) {
            // if it does, get the delegate account address
            let controller_delegate = IDelegateAccountDispatcher { contract_address: owner_address }
                .delegate_account();
            if controller_delegate.is_non_zero() {
                // and return it if it's non zero
                return controller_delegate;
            }
        }

        // otherwise return the owner address
        return owner_address;
    }

    fn _get_rank(self: @ContractState, adventurer_id: felt252) -> u8 {
        let leaderboard = self._leaderboard.read();
        if (leaderboard.first.adventurer_id == adventurer_id.try_into().unwrap()) {
            1
        } else if (leaderboard.second.adventurer_id == adventurer_id.try_into().unwrap()) {
            2
        } else if (leaderboard.third.adventurer_id == adventurer_id.try_into().unwrap()) {
            3
        } else {
            0
        }
    }

    /// @title Update Leaderboard
    /// @notice Updates the leaderboard and emits an event.
    /// @dev This function is called when the leaderboard is updated.
    /// @param self A reference to the ContractState object.
    /// @param adventurer_id A felt252 representing the unique ID of the adventurer.
    /// @param adventurer A reference to the adventurer.
    fn _update_leaderboard(
        ref self: ContractState, adventurer_id: felt252, adventurer: Adventurer
    ) {
        // get current leaderboard which will be mutated as part of this function
        let mut leaderboard = self._leaderboard.read();

        // create a score struct for the players score
        let player_score = Score {
            adventurer_id: adventurer_id.try_into().unwrap(),
            xp: adventurer.xp,
            gold: adventurer.gold
        };

        let mut player_rank = 0;

        // shift leaderboard based on players placement
        if player_score.xp > leaderboard.first.xp {
            leaderboard.third = leaderboard.second;
            leaderboard.second = leaderboard.first;
            leaderboard.first = player_score;
            player_rank = 1;
        } else if player_score.xp > leaderboard.second.xp {
            leaderboard.third = leaderboard.second;
            leaderboard.second = player_score;
            player_rank = 2;
        } else if player_score.xp > leaderboard.third.xp {
            leaderboard.third = player_score;
            player_rank = 3;
        }

        // if player xp is higher than minimum score for payouts
        if adventurer.xp >= MINIMUM_SCORE_FOR_DEATH_RANK {
            // record rank at death for onchain fun
            _record_adventurer_rank_at_death(ref self, adventurer_id, player_rank);
        }

        // emit new high score event
        __event_NewHighScore(ref self, adventurer_id, adventurer, player_rank);

        // save leaderboard
        self._leaderboard.write(leaderboard);
    }

    /// @title Get VRF Max Callback Fee
    /// @notice Gets the maximum VRF callback fee based on the chain ID.
    /// @dev This function is called when the maximum VRF callback fee is needed.
    /// @param self A reference to the ContractState object.
    /// @return A u128 representing the maximum VRF callback fee.
    fn _get_vrf_max_callback_fee(self: @ContractState) -> u128 {
        let chain_id = get_tx_info().unbox().chain_id;
        if chain_id == MAINNET_CHAIN_ID {
            _dollar_to_wei(self, VRF_MAX_CALLBACK_MAINNET.into())
        } else if chain_id == SEPOLIA_CHAIN_ID {
            // $3 for non-mainnet to prevent interference from gas price swings
            _dollar_to_wei(self, VRF_MAX_CALLBACK_TESTNET.into())
        } else {
            panic_with_felt252('network does not support vrf')
        }
    }

    // ---------- EVENTS ---------- //
    #[derive(Copy, Drop, Serde, starknet::Event)]
    struct AdventurerState {
        owner: ContractAddress,
        adventurer_id: felt252,
        level_seed: u64,
        adventurer: Adventurer
    }

    #[derive(Copy, Drop, Serde, starknet::Event)]
    struct AdventurerStateWithBag {
        adventurer_state: AdventurerState,
        bag: Bag
    }

    #[derive(Drop, starknet::Event)]
    struct StartGame {
        adventurer_state: AdventurerState,
        adventurer_meta: AdventurerMetadata,
        adventurer_name: felt252,
        custom_renderer: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct DiscoveredGold {
        adventurer_state: AdventurerState,
        amount: u16
    }

    #[derive(Drop, starknet::Event)]
    struct DiscoveredHealth {
        adventurer_state: AdventurerState,
        amount: u16
    }
    #[derive(Drop, starknet::Event)]
    struct DiscoveredLoot {
        adventurer_state: AdventurerState,
        item_id: u8
    }

    #[derive(Drop, Serde, starknet::Event)]
    struct ObstacleEvent {
        adventurer_state: AdventurerState,
        obstacle_details: ObstacleDetails,
    }

    #[derive(Drop, Serde)]
    struct ObstacleDetails {
        id: u8,
        level: u16,
        damage_taken: u16,
        damage_location: u8,
        critical_hit: bool,
        adventurer_xp_reward: u16,
        item_xp_reward: u16,
    }

    #[derive(Drop, starknet::Event)]
    struct DodgedObstacle {
        obstacle_event: ObstacleEvent
    }

    #[derive(Drop, starknet::Event)]
    struct HitByObstacle {
        obstacle_event: ObstacleEvent
    }

    #[derive(Drop, starknet::Event)]
    struct DiscoveredBeast {
        adventurer_state: AdventurerState,
        seed: u32,
        id: u8,
        beast_specs: CombatSpec,
    }

    #[derive(Drop, Serde, starknet::Event)]
    struct BattleDetails {
        seed: u32,
        id: u8,
        beast_specs: CombatSpec,
        damage: u16,
        critical_hit: bool,
        location: u8,
    }

    #[derive(Drop, starknet::Event)]
    struct AmbushedByBeast {
        adventurer_state: AdventurerState,
        beast_battle_details: BattleDetails,
    }

    #[derive(Drop, starknet::Event)]
    struct AttackedBeast {
        adventurer_state: AdventurerState,
        beast_battle_details: BattleDetails,
    }

    #[derive(Drop, starknet::Event)]
    struct AttackedByBeast {
        adventurer_state: AdventurerState,
        beast_battle_details: BattleDetails,
    }

    #[derive(Drop, starknet::Event)]
    struct SlayedBeast {
        adventurer_state: AdventurerState,
        seed: u32,
        id: u8,
        beast_specs: CombatSpec,
        damage_dealt: u16,
        critical_hit: bool,
        xp_earned_adventurer: u16,
        xp_earned_items: u16,
        gold_earned: u16,
    }

    #[derive(Drop, Serde)]
    struct FleeEvent {
        adventurer_state: AdventurerState,
        seed: u32,
        id: u8,
        beast_specs: CombatSpec,
    }

    #[derive(Drop, starknet::Event)]
    struct FleeFailed {
        flee_event: FleeEvent
    }

    #[derive(Drop, starknet::Event)]
    struct FleeSucceeded {
        flee_event: FleeEvent
    }

    #[derive(Drop, starknet::Event)]
    struct PurchasedPotions {
        adventurer_state: AdventurerState,
        quantity: u8,
        cost: u16,
        health: u16,
    }

    #[derive(Drop, starknet::Event)]
    struct PurchasedItems {
        adventurer_state_with_bag: AdventurerStateWithBag,
        purchases: Array<LootWithPrice>,
    }

    #[derive(Clone, Drop, starknet::Event)]
    struct EquipmentChanged {
        adventurer_state_with_bag: AdventurerStateWithBag,
        equipped_items: Array<u8>,
        bagged_items: Array<u8>,
        dropped_items: Array<u8>,
    }

    #[derive(Clone, Drop, starknet::Event)]
    struct EquippedItems {
        adventurer_state_with_bag: AdventurerStateWithBag,
        equipped_items: Array<u8>,
        unequipped_items: Array<u8>,
    }

    #[derive(Clone, Drop, starknet::Event)]
    struct DroppedItems {
        adventurer_state_with_bag: AdventurerStateWithBag,
        item_ids: Array<u8>,
    }

    #[derive(Drop, starknet::Event)]
    struct ItemsLeveledUp {
        adventurer_state: AdventurerState,
        items: Array<ItemLeveledUp>,
    }

    #[derive(Drop, starknet::Event)]
    struct NewHighScore {
        adventurer_state: AdventurerState,
        rank: u8, // 1-3
    }

    #[derive(Clone, Drop, starknet::Event)]
    struct AdventurerDied {
        adventurer_state: AdventurerState,
        death_details: DeathDetails
    }

    #[derive(Clone, Drop, Serde)]
    struct DeathDetails {
        killed_by_beast: u8,
        killed_by_obstacle: u8,
        killed_by_old_age: bool,
    }

    #[derive(Drop, starknet::Event)]
    struct AdventurerLeveledUp {
        adventurer_state: AdventurerState,
        previous_level: u8,
        new_level: u8,
    }

    #[derive(Drop, starknet::Event)]
    struct UpgradesAvailable {
        adventurer_state: AdventurerState,
        items: Array<u8>,
    }

    #[derive(Drop, starknet::Event)]
    struct AdventurerUpgraded {
        adventurer_state_with_bag: AdventurerStateWithBag,
        strength_increase: u8,
        dexterity_increase: u8,
        vitality_increase: u8,
        intelligence_increase: u8,
        wisdom_increase: u8,
        charisma_increase: u8,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardDistribution {
        first_place: PlayerReward,
        second_place: PlayerReward,
        third_place: PlayerReward,
        client: ClientReward,
        dao: u128,
        pg: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct PriceChangeEvent {
        previous_price: u128,
        new_price: u128,
        lords_price: u128,
        changer: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct RequestedLevelSeed {
        adventurer_id: felt252,
        vrf_address: ContractAddress,
        seed: u64
    }

    #[derive(Drop, starknet::Event)]
    struct ReceivedLevelSeed {
        adventurer_id: felt252,
        vrf_address: ContractAddress,
        seed: u64,
        request_id: u64
    }

    #[derive(Drop, starknet::Event)]
    struct RequestedItemSpecialsSeed {
        adventurer_id: felt252,
        vrf_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ReceivedItemSpecialsSeed {
        adventurer_id: felt252,
        vrf_address: ContractAddress,
        seed: felt252,
        request_id: u64
    }

    #[derive(Drop, starknet::Event)]
    struct UpdatedAdventurerName {
        adventurer_id: felt252,
        name: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct SetAdventurerObituary {
        adventurer_id: felt252,
        obituary: ByteArray,
    }

    #[derive(Drop, starknet::Event)]
    struct ClaimedFreeGame {
        adventurer_id: felt252,
        collection_address: ContractAddress,
        token_id: u128
    }

    #[derive(Drop, starknet::Event)]
    struct NewCollectionTotal {
        collection_address: ContractAddress,
        xp: u32,
        games_played: u16,
    }

    #[derive(Drop, Serde)]
    struct PlayerReward {
        adventurer_id: felt252,
        rank: u8,
        amount: u128,
        address: ContractAddress,
    }

    #[derive(Drop, Serde)]
    struct ClientReward {
        amount: u128,
        address: ContractAddress,
    }

    fn __event_RewardDistribution(
        ref self: ContractState,
        rewards: Rewards,
        leaderboard: Leaderboard,
        client_address: ContractAddress
    ) {
        let first_place_address = _get_owner(@self, leaderboard.first.adventurer_id.into());
        let second_place_address = _get_owner(@self, leaderboard.second.adventurer_id.into());
        let third_place_address = _get_owner(@self, leaderboard.third.adventurer_id.into());

        let reward_distribution = RewardDistribution {
            first_place: PlayerReward {
                adventurer_id: leaderboard.first.adventurer_id.into(),
                rank: 1,
                amount: rewards.FIRST_PLACE,
                address: first_place_address
            },
            second_place: PlayerReward {
                adventurer_id: leaderboard.second.adventurer_id.into(),
                rank: 2,
                amount: rewards.SECOND_PLACE,
                address: second_place_address
            },
            third_place: PlayerReward {
                adventurer_id: leaderboard.third.adventurer_id.into(),
                rank: 3,
                amount: rewards.THIRD_PLACE,
                address: third_place_address
            },
            client: ClientReward { amount: rewards.CLIENT_PROVIDER, address: client_address },
            dao: rewards.BIBLIO,
            pg: rewards.PG,
        };
        self.emit(reward_distribution);
    }
    fn __event_RequestedLevelSeed(ref self: ContractState, adventurer_id: felt252, seed: u64) {
        let vrf_address = self._vrf_dispatcher.read().contract_address;
        self.emit(RequestedLevelSeed { adventurer_id, vrf_address, seed });
    }
    fn __event_ReceivedLevelSeed(
        ref self: ContractState,
        adventurer_id: felt252,
        vrf_address: ContractAddress,
        request_id: u64
    ) {
        let seed = _get_level_seed(@self, adventurer_id);
        self.emit(ReceivedLevelSeed { adventurer_id, vrf_address, seed, request_id });
    }
    fn _event_RequestedItemSpecialsSeed(ref self: ContractState, adventurer_id: felt252) {
        let vrf_address = self._vrf_dispatcher.read().contract_address;
        self.emit(RequestedItemSpecialsSeed { adventurer_id, vrf_address });
    }
    fn _event_ReceivedItemSpecialsSeed(
        ref self: ContractState,
        adventurer_id: felt252,
        vrf_address: ContractAddress,
        seed: felt252,
        request_id: u64
    ) {
        self.emit(ReceivedItemSpecialsSeed { adventurer_id, vrf_address, seed, request_id });
    }
    fn __event_AdventurerUpgraded(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        bag: Bag,
        stat_upgrades: Stats
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let adventurer_state_with_bag = AdventurerStateWithBag { adventurer_state, bag };
        self
            .emit(
                AdventurerUpgraded {
                    adventurer_state_with_bag,
                    strength_increase: stat_upgrades.strength,
                    dexterity_increase: stat_upgrades.dexterity,
                    vitality_increase: stat_upgrades.vitality,
                    intelligence_increase: stat_upgrades.intelligence,
                    wisdom_increase: stat_upgrades.wisdom,
                    charisma_increase: stat_upgrades.charisma,
                }
            );
    }

    fn __event_StartGame(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        adventurer_meta: AdventurerMetadata,
        adventurer_name: felt252,
        custom_renderer: ContractAddress
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self
            .emit(
                StartGame { adventurer_state, adventurer_meta, adventurer_name, custom_renderer }
            );
    }

    fn __event_DiscoveredGold(
        ref self: ContractState, adventurer: Adventurer, adventurer_id: felt252, amount: u16
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(DiscoveredGold { adventurer_state, amount });
    }

    fn __event_DiscoveredHealth(
        ref self: ContractState, adventurer: Adventurer, adventurer_id: felt252, amount: u16
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(DiscoveredHealth { adventurer_state, amount });
    }

    fn __event_DiscoveredLoot(
        ref self: ContractState, adventurer: Adventurer, adventurer_id: felt252, item_id: u8
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(DiscoveredLoot { adventurer_state, item_id });
    }

    fn __event_ObstacleEncounter(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        dodged: bool,
        obstacle_details: ObstacleDetails,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };

        let obstacle_event = ObstacleEvent { adventurer_state, obstacle_details, };

        if dodged {
            self.emit(DodgedObstacle { obstacle_event });
        } else {
            self.emit(HitByObstacle { obstacle_event });
        }
    }

    fn __event_DiscoveredBeast(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        beast: Beast
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };

        let discovered_beast_event = DiscoveredBeast {
            adventurer_state, seed, id: beast.id, beast_specs: beast.combat_spec
        };
        self.emit(discovered_beast_event);
    }

    fn __event_AttackedBeast(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        beast_battle_details: BattleDetails
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(AttackedBeast { adventurer_state, beast_battle_details });
    }

    fn __event_AttackedByBeast(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        beast_battle_details: BattleDetails
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(AttackedByBeast { adventurer_state, beast_battle_details });
    }

    fn __event_AmbushedByBeast(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        beast_battle_details: BattleDetails
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(AmbushedByBeast { adventurer_state, beast_battle_details });
    }

    fn __event_SlayedBeast(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        beast: Beast,
        damage_dealt: u16,
        critical_hit: bool,
        xp_earned_adventurer: u16,
        xp_earned_items: u16,
        gold_earned: u16
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let slayed_beast_event = SlayedBeast {
            adventurer_state,
            seed,
            id: beast.id,
            beast_specs: beast.combat_spec,
            damage_dealt,
            critical_hit,
            xp_earned_adventurer,
            xp_earned_items,
            gold_earned,
        };
        self.emit(slayed_beast_event);
    }

    fn __event_FleeFailed(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        beast: Beast
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let flee_event = FleeEvent {
            adventurer_state, seed, id: beast.id, beast_specs: beast.combat_spec
        };
        self.emit(FleeFailed { flee_event });
    }

    fn __event_FleeSucceeded(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        seed: u32,
        beast: Beast
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let flee_event = FleeEvent {
            adventurer_state, seed, id: beast.id, beast_specs: beast.combat_spec
        };
        self.emit(FleeSucceeded { flee_event });
    }

    fn __event_EquipmentChanged(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        bag: Bag,
        equipped_items: Array<u8>,
        bagged_items: Array<u8>,
        dropped_items: Array<u8>,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let adventurer_state_with_bag = AdventurerStateWithBag { adventurer_state, bag };
        self
            .emit(
                EquipmentChanged {
                    adventurer_state_with_bag, equipped_items, bagged_items, dropped_items,
                }
            );
    }

    fn __event_EquippedItems(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        bag: Bag,
        equipped_items: Array<u8>,
        unequipped_items: Array<u8>,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let adventurer_state_with_bag = AdventurerStateWithBag { adventurer_state, bag };
        let equipped_items_event = EquippedItems {
            adventurer_state_with_bag, equipped_items, unequipped_items,
        };
        self.emit(equipped_items_event);
    }

    fn __event_DroppedItems(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        bag: Bag,
        item_ids: Array<u8>,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let adventurer_state_with_bag = AdventurerStateWithBag { adventurer_state, bag };
        self.emit(DroppedItems { adventurer_state_with_bag, item_ids });
    }

    fn __event_ItemsLeveledUp(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        items: Array<ItemLeveledUp>,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(ItemsLeveledUp { adventurer_state, items });
    }

    fn __event_NewHighScore(
        ref self: ContractState, adventurer_id: felt252, adventurer: Adventurer, rank: u8
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(NewHighScore { adventurer_state, rank });
    }

    fn __event_AdventurerDied(ref self: ContractState, adventurer_died_event: AdventurerDied) {
        self.emit(adventurer_died_event);
    }

    fn __event_AdventurerLeveledUp(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        previous_level: u8,
        new_level: u8,
    ) {
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id),
            adventurer_id,
            level_seed: _get_level_seed(@self, adventurer_id),
            adventurer
        };
        self.emit(AdventurerLeveledUp { adventurer_state, previous_level, new_level });
    }

    fn __event_UpgradesAvailable(
        ref self: ContractState, adventurer: Adventurer, adventurer_id: felt252,
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let items = _get_market(@self, adventurer_id, adventurer.stat_upgrades_available);
        self.emit(UpgradesAvailable { adventurer_state, items });
    }

    fn __event_PurchasedItems(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        bag: Bag,
        purchases: Array<LootWithPrice>
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        let adventurer_state_with_bag = AdventurerStateWithBag { adventurer_state, bag };
        self.emit(PurchasedItems { adventurer_state_with_bag, purchases });
    }

    fn __event_PurchasedPotions(
        ref self: ContractState,
        adventurer: Adventurer,
        adventurer_id: felt252,
        quantity: u8,
        cost: u16,
        health: u16
    ) {
        let level_seed = _get_level_seed(@self, adventurer_id);
        let adventurer_state = AdventurerState {
            owner: _get_owner(@self, adventurer_id), adventurer_id, level_seed, adventurer
        };
        self.emit(PurchasedPotions { adventurer_state, quantity, cost, health, });
    }

    fn __event_ClaimedFreeGame(
        ref self: ContractState,
        adventurer_id: felt252,
        collection_address: ContractAddress,
        token_id: u128
    ) {
        self.emit(ClaimedFreeGame { adventurer_id, collection_address, token_id });
    }

    fn __event_NewCollectionTotal(
        ref self: ContractState, collection_address: ContractAddress, xp: u32, games_played: u16
    ) {
        self.emit(NewCollectionTotal { collection_address, xp, games_played });
    }

    fn _free_game_available(
        self: @ContractState, token_type: FreeGameTokenType, token_id: u128
    ) -> bool {
        _last_usage(self, token_type, token_id) + token_type.get_cooldown() <= get_block_timestamp()
    }

    /// @title Pay With Special Token
    /// @notice Play with the token for the given token type
    /// @param token_type The type of the token
    /// @param token_id The ID of the token
    fn _pay_with_special_token(
        ref self: ContractState, token_type: FreeGameTokenType, token_id: u128
    ) {
        // assert caller owns token
        let token_dispatcher = _get_token_dispatcher(@self, token_type);
        let token_owner = token_dispatcher.owner_of(token_id.into());
        assert(token_owner == get_caller_address(), messages::NOT_OWNER_OF_TOKEN);

        // assert token has a free game available
        assert(_free_game_available(@self, token_type, token_id), messages::FREE_GAME_UNAVAILABLE);

        // if this is a token for the launch tournament, verify it participated in the tournament
        if token_type == FreeGameTokenType::LaunchTournamentChampion {
            // get hash of collection and token id
            let token_hash = _get_token_hash(@self, token_dispatcher.contract_address, token_id);

            // assert token participated in the launch tournament
            _assert_participated_in_tournament(@self, token_hash);
        }

        // save last usage timestamp
        self
            ._previous_free_game_timestamp
            .write((token_dispatcher.contract_address, token_id), get_block_timestamp());
    }

    /// @title Get Token Dispatcher
    /// @notice Get the token dispatcher for the given token type
    /// @param token_type The type of the token
    /// @return The token dispatcher
    fn _get_token_dispatcher(
        self: @ContractState, token_type: FreeGameTokenType
    ) -> IERC721Dispatcher {
        match token_type {
            FreeGameTokenType::GoldenToken => self._golden_token_dispatcher.read(),
            FreeGameTokenType::LaunchTournamentChampion => self
                ._launch_tournament_champions_dispatcher
                .read(),
        }
    }

    /// @title Get Token Address
    /// @notice Get the address of the token for the given token type
    /// @param token_type The type of the token
    /// @return The address of the token
    fn _get_token_address(self: @ContractState, token_type: FreeGameTokenType) -> ContractAddress {
        match token_type {
            FreeGameTokenType::GoldenToken => self._golden_token_dispatcher.read().contract_address,
            FreeGameTokenType::LaunchTournamentChampion => self
                ._launch_tournament_champions_dispatcher
                .read()
                .contract_address,
        }
    }

    /// @title Get Last Usage
    /// @notice Get the last usage timestamp of the token for the given token type
    /// @param token_type The type of the token
    /// @param token_id The ID of the token
    /// @return The last usage timestamp
    fn _last_usage(self: @ContractState, token_type: FreeGameTokenType, token_id: u128) -> u64 {
        let token_address = _get_token_address(self, token_type);
        self._previous_free_game_timestamp.read((token_address, token_id))
    }

    #[abi(embed_v0)]
    impl ERC721Mixin of IERC721Mixin<ContractState> {
        // IERC721
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            ERC721::balance_of(self, account)
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            ERC721::owner_of(self, token_id)
        }

        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>
        ) {
            ERC721::safe_transfer_from(ref self, from, to, token_id, data);
        }

        fn transfer_from(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            ERC721::transfer_from(ref self, from, to, token_id);
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            ERC721::approve(ref self, to, token_id);
        }

        fn set_approval_for_all(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            ERC721::set_approval_for_all(ref self, operator, approved);
        }

        fn get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            ERC721::get_approved(self, token_id)
        }

        fn is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            ERC721::is_approved_for_all(self, owner, operator)
        }

        // IERC721Metadata
        fn name(self: @ContractState) -> ByteArray {
            ERC721Metadata::name(self)
        }

        fn symbol(self: @ContractState) -> ByteArray {
            ERC721Metadata::symbol(self)
        }

        fn token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            self.erc721._require_owned(token_id);

            let adventurer_id = token_id.try_into().unwrap();

            // use custom renderer if available
            let renderer_address = _get_adventurer_renderer(self, adventurer_id);

            let adventurer = _load_adventurer(self, adventurer_id);
            let adventurer_name = _load_adventurer_name(self, adventurer_id);
            let adventurer_metadata = _load_adventurer_metadata(self, adventurer_id);
            let bag = _load_bag(self, adventurer_id);
            let item_specials_seed = _get_item_specials_seed(self, adventurer_id);
            let current_rank = _get_rank(self, adventurer_id);

            IRenderContractDispatcher { contract_address: renderer_address }
                .token_uri(
                    token_id,
                    adventurer,
                    adventurer_name,
                    adventurer_metadata,
                    bag,
                    item_specials_seed,
                    adventurer_metadata.rank_at_death,
                    current_rank,
                )
        }

        // IERC721CamelOnly
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            ERC721CamelOnly::balanceOf(self, account)
        }

        fn ownerOf(self: @ContractState, tokenId: u256) -> ContractAddress {
            ERC721CamelOnly::ownerOf(self, tokenId)
        }

        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256,
            data: Span<felt252>
        ) {
            ERC721CamelOnly::safeTransferFrom(ref self, from, to, tokenId, data);
        }

        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256
        ) {
            ERC721CamelOnly::transferFrom(ref self, from, to, tokenId);
        }

        fn setApprovalForAll(ref self: ContractState, operator: ContractAddress, approved: bool) {
            ERC721CamelOnly::setApprovalForAll(ref self, operator, approved);
        }

        fn getApproved(self: @ContractState, tokenId: u256) -> ContractAddress {
            ERC721CamelOnly::getApproved(self, tokenId)
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            ERC721CamelOnly::isApprovedForAll(self, owner, operator)
        }

        // IERC721MetadataCamelOnly
        fn tokenURI(self: @ContractState, tokenId: u256) -> ByteArray {
            Self::token_uri(self, tokenId)
        }

        // ISRC5 snake case
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            SRC5::supports_interface(self, interface_id)
        }

        // ISRC5 camel case
        fn supportsInterface(self: @ContractState, interfaceId: felt252) -> bool {
            SRC5::supports_interface(self, interfaceId)
        }
    }
}
