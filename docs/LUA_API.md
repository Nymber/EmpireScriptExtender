# Empire Lua API - campaign and battle, enumerated live

The single reference for **both** scripting surfaces Empire exposes. Everything
here was read out of a running game with ESE, not inferred from the handful of
calls vanilla scripts happen to make.

This file is the campaign API and the battle API in one place. They used to be
split by *format* (prose vs spreadsheet) rather than by anything a reader cares
about, so the battle surface was easy to miss. `battle_lua_api.csv` is still
here only because `ese_proxy.c` names it; do not treat it as a second reference.

## Which `lua_State` am I in?

This is the first question for every API call, because the same name can exist
in one state and not another, and the failure is silent.

| state | reach it with | holds | part |
|---|---|---|---|
| campaign scripting | `ese.ps1 "<lua>"` | `conditions`, `effect`, `events`, `data` | 1, 2 |
| campaign UI root | `ese.ps1 -UI "<lua>"` | `Component`, `UIComponent`, `Localisation` | - |
| battle | `ese.ps1 "@battle <lua>"` | 208 battle natives | 3 |
| ~109 per-component | not addressable | transient, pointers go stale | - |

A campaign must be loaded before the campaign state exists at all; a battle
must be in progress before the battle state exists.

Mods do not edit either autoexec loader. They are folders under
`EmpireScriptExtender/lua/` with a manifest and an activation record in
`ese_mods.lua`; `lua/README.md` is the short version. The functions this file
does not list — `ESE_Log`, `ESE_Protect`,
`ESE_Call`, `ESE_Trace` and the rest — are registered from the `kNatives[]`
table in `ESE/ese_proxy.c`, and the two detours underneath them are
`A_lua_getfield` / `A_lua_setfield` in the same file.


---

Dumped 2026-09-18 18:45 with ESE (`ese.ps1`) against a loaded
campaign. Read out of the campaign `lua_State` itself, so this is the REAL
surface - not inferred from the handful of calls vanilla scripts happen to use.

**This supersedes the ~11 `conditions` functions previously documented.**
It also answers, without a debug build, the question the shipped comment poses:
*"For a list of all events supported create a documentation directory ... run a
debug build"* - the 147 event names are below.

Environment (`getfenv(0)`): CampaignName, CommandQueue (userdata), LocalFaction,
conditions, data, effect, events, decoda_name - plus anything ESE registers.

# PART 1 - CAMPAIGN: the read API

## `conditions` - 279 entries

```
AdjacentRegionRebelling
AdviceDisplayed
AdviceJustDisplayed
AdviceThreadProgress
ArmyIsAlliedCampaign
ArmyIsLocalCampaign
BattleAllianceIsAttacker
BattleAllianceIsPlayers
BattleAllianceNumberOfShips
BattleAllianceNumberOfUnits
BattleEnemyAlliancePercentageCanHide
BattleEnemyAlliancePercentageOfClassAndCategory
BattleEnemyAlliancePercentageOfMountType
BattleEnemyAlliancePercentageOfSpecialAbility
BattleEnemyAlliancePercentageOfUnitCategory
BattleEnemyAlliancePercentageOfUnitClass
BattleEnemyDirectionOfMeleeAttack
BattleEnemyHasMissileSuperiority
BattleEnemyShipActionStatus
BattleEnemyShipOnFire
BattleEnemyUnitActionStatus
BattleEnemyUnitCategory
BattleEnemyUnitClass
BattleEnemyUnitCurrentFormation
BattleEnemyUnitOnLeftFlank
BattleEnemyUnitOnRightFlank
BattleEnemyUnitSpecialAbilitySupported
BattleEnemyUnitTechnologySupported
BattleHasCoverBuildings
BattleHasCoverWalls
BattleIsLandConflict
BattleIsNavalConflict
BattleIsSiegeConflict
BattlePlayerAllianceDefendingHill
BattlePlayerAlliancePercentageCanHide
BattlePlayerAlliancePercentageOfAmmoType
BattlePlayerAlliancePercentageOfClassAndCategory
BattlePlayerAlliancePercentageOfMountType
BattlePlayerAlliancePercentageOfSpecialAbility
BattlePlayerAlliancePercentageOfTechnology
BattlePlayerAlliancePercentageOfUnitCategory
BattlePlayerAlliancePercentageOfUnitClass
BattlePlayerAllianceToEnemyAllianceRatio
BattlePlayerDefendingFort
BattlePlayerDirectionOfMeleeAttack
BattlePlayerDirectionOfMissileAttack
BattlePlayerSailsPercentageDamaged
BattlePlayerShipActionStatus
BattlePlayerShipClass
BattlePlayerUnitActionStatus
BattlePlayerUnitAmmoType
BattlePlayerUnitCategory
BattlePlayerUnitClass
BattlePlayerUnitCurrentFormation
BattlePlayerUnitDefendingHill
BattlePlayerUnitEngaged
BattlePlayerUnitEngagedInMelee
BattlePlayerUnitMountType
BattlePlayerUnitMovingFast
BattlePlayerUnitSpecialAbilityActive
BattlePlayerUnitSpecialAbilitySupported
BattlePlayerUnitTechnologySupported
BattleResult
BattleShipIsPlayers
BattleShipSailsPercentageDamage
BattleType
BattleUnitIsAllied
BattleUnitIsPlayers
BattlesFought
BuildingLevelName
BuildingTypeExistsAtSettlement
BuildingTypeExistsAtSlot
CampaignBattleType
CampaignName
CampaignPercentageOfOwnCaptured
CampaignPercentageOfOwnKilled
CampaignPercentageOfOwnRouted
CampaignPercentageOfThemCaptured
CampaignPercentageOfThemKilled
CampaignPercentageOfThemRouted
CampaignPercentageOfUnitCategory
CanGenerateHistoricalCharacter
CharacterAbility
CharacterAttribute
CharacterBuildingConstructed
CharacterCapturedEnemyShip
CharacterCultureType
CharacterDuelWeapon
CharacterEndedInAmbushPosition
CharacterFactionAdmiralCount
CharacterFactionGeneralCount
CharacterFactionHasTechType
CharacterFactionName
CharacterFactionSubcultureType
CharacterForename
CharacterFoughtCulture
CharacterHasTrait
CharacterHoldsPost
CharacterInBuildingOfChain
CharacterInBuildingType
CharacterInEnemyLands
CharacterInHomeRegion
CharacterInOwnFactionLands
CharacterInRegion
CharacterInTheatre
CharacterIsAlliedCampaign
CharacterIsEnemyCampaign
CharacterIsLocalCampaign
CharacterMPPercentageRemaining
CharacterMinisterialPosition
CharacterNumberOfChildren
CharacterRouted
CharacterSurname
CharacterTrait
CharacterTurnsAtHome
CharacterTurnsAtSea
CharacterTurnsInEnemyLands
CharacterType
CharacterWasAttacker
CharacterWonBattle
CharacterWonDuel
CommanderAncillary
CommanderFoughtInBattle
CommanderFoughtInMelee
CommanderTrait
DateInRange
DefensiveSiegesFought
DefensiveSiegesWon
EnemyArmyGreaterCombatStrength
FactionAllyCount
FactionBuildingExists
FactionCanBuildBuilding
FactionCashFlow
FactionDestroyedByCharacterFaction
FactionExists
FactionGovernmentType
FactionHasAllies
FactionIsAlliedCampaign
FactionIsHuman
FactionIsLocal
FactionLeadersAttribute
FactionLeadersTrait
FactionName
FactionPatrioticFervour
FactionSupportCostsPercentage
FactionTaxLevel
FactionTechExists
FactionTradeCommodityExists
FactionTradeValue
FactionTradeValuePercentage
FactionTreasury
FactionTreasuryWorldPercentage
FactionWarWeariness
FactionwideAncillaryTypeExists
FortBuildingQueueIdleDespiteCash
FortIsLocal
FortName
GovernorTaxLevel
GovernorshipTaxLevel
HasUnspecialisedPort
InPort
InSettlement
InsurrectionCrushed
IsBesieging
IsBlockading
IsBuildingInChain
IsBuildingOfType
IsCarryingTroops
IsChildOf
IsColony
IsComponentType
IsFactionLeader
IsFactionLeaderFemale
IsGarrisoned
IsHomeRegion
IsMessageType
IsMultiplayer
IsPlayerTurn
IsPortGarrisoned
IsTheatreGovernor
IsTriggerableHistoricalEvent
IsUnderBlockade
IsUnderSiege
LandTradeRouteRaided
LosingMoney
MapPosition
MissionName
NoActionThisTurn
OffensiveSiegesFought
OffensiveSiegesWon
OnAWarFooting
ParentId
PercentageUnspentIncome
PlayerFactionIsAttacker
PortBlockaded
PortBlockadedLocal
RandomPercentCampaign
RegionBuildableSlotEmpty
RegionBuildingFinished
RegionClamoursReform
RegionCultureIsFactionCulture
RegionDemands
RegionEconomicGrowthLow
RegionFoodShortageEmigration
RegionGovernorAttribute
RegionHasFoodShortages
RegionHasUnexportedTrade
RegionIsLocal
RegionPopulationGrowthLow
RegionPopulationLow
RegionPopulationMaxReached
RegionRebels
RegionReligionIsStateReligion
RegionReligiousEmigration
RegionResourceExists
RegionResourceExploited
RegionRiots
RegionSlotBuildingCount
RegionSlotBuildingCultureExists
RegionSlotBuildingTypeCount
RegionSlotBuildingTypeExists
RegionSlotCount
RegionSlotEmptyCount
RegionSlotTypeExists
RegionTaxExempt
RegionTaxLevel
RegionTaxTownWealthGrowthReduction
RegionTownWealthGrowth
RegionWealthDecrease
RegionWealthIncrease
ResearchCategory
ResearchQueueIdle
ResearchType
ResearchTypeUniqueToFaction
RoadsAtMaxLevel
SeaTradeRouteRaided
SettlementBuildingQueueIdleDespiteCash
SettlementFortificationsBuildingQueueIdleDespiteCash
SettlementIsLocal
SettlementName
SettlementRoadBuildingQueueIdleDespiteCash
SlotBuildingQueueIdleDespiteCash
SlotIsAlliedCampaign
SlotIsLocal
SlotName
SlotType
SupportCostsPercentage
TargetArmyGreaterCombatStrength
TargetCharacterIsAlliedCampaign
TargetCharacterIsEnemyCampaign
TargetInStrikingRangeOfEnemy
TaxCollectionLimited
TaxLevel
TradePortsAtMaxLevel
TradeRouteIsEnemy
TradeRouteIsLocal
TradeRouteLimitReached
TurnNumber
TurnsSinceThreadLastAdvanced
UnitCategory
UnitClass
UnitCrushedInsurrection
UnitCultureType
UnitFoughtInBattle
UnitFoughtInMelee
UnitInTheatre
UnitOnContinent
UnitRouted
UnitSufferedCasualties
UnitTrait
UnitType
UnitWonBattle
UnusedInternationalTradeRoute
WarEndedCharacterFaction
WarStartedCharacterFaction
WorldResourceExists
WorldResourceExploited
WorldwideAncillaryTypeExists
WouldRebellionInRegionBeRevolution
```

## `effect` - 12 entries

```
adjust_treasury
advance_contextual_advice_thread
advance_scripted_advice_thread
advice
ancillary
historical_character
historical_event
remove_ancillary
remove_trait
rewind_scripted_advice
suspend_contextual_advice
trait
```

## `events` - 147 entries

```
AdviceDismissed
AdviceIssued
AdviceSuperseded
ArmySabotageAttemptSuccess
AssassinationAttemptSuccess
BattleCommandingShipRouts
BattleCommandingUnitRouts
BattleConflictPhaseCommenced
BattleDeploymentPhaseCommenced
BattleShipAttacksEnemyShip
BattleShipCaughtFire
BattleShipMagazineExplosion
BattleShipRouts
BattleShipRunAground
BattleShipSailingIntoWind
BattleShipSurrendered
BattleUnitAttacksBuilding
BattleUnitAttacksEnemyUnit
BattleUnitAttacksWalls
BattleUnitCapturesBuilding
BattleUnitDestroysBuilding
BattleUnitRouts
BattleUnitUsingBuilding
BattleUnitUsingWall
BuildingCardSelected
BuildingCompleted
BuildingConstructionIssuedByPlayer
BuildingInfoPanelOpenedCampaign
CameraMoverFinished
CampaignArmiesMerge
CampaignBuildingDamaged
CampaignSettlementAttacked
CampaignSlotAttacked
CharacterAttacksAlly
CharacterCompletedBattle
CharacterCreated
CharacterDamagedByDisaster
CharacterInfoPanelOpened
CharacterPromoted
CharacterSelected
CharacterTurnEnd
CharacterTurnStart
ComponentLClickUp
DuelDemanded
DuelFought
DummyEvent
EspionageAgentApprehended
EventMessageOpenedBattle
EventMessageOpenedCampaign
FactionGovernmentTypeChanged
FactionRoundStart
FactionTurnEnd
FactionTurnStart
FortSelected
GarrisonResidenceCaptured
HistoricalCharacters
HistoricalEvents
HudRefresh
IncomingMessage
LandTradeRouteRaided
LoadingGame
LocationEntered
LocationUnveiled
MissionCancelled
MissionCheckAssassination
MissionCheckBlockadePort
MissionCheckBuild
MissionCheckCaptureCity
MissionCheckDuel
MissionCheckEngageCharacter
MissionCheckEngageFaction
MissionCheckGainMilitaryAccess
MissionCheckMakeAlliance
MissionCheckMakeTradeAgreement
MissionCheckRecruit
MissionCheckResearch
MissionCheckSpyOnCity
MissionEvaluateAssassination
MissionEvaluateBlockadePort
MissionEvaluateBuild
MissionEvaluateCaptureCity
MissionEvaluateDuel
MissionEvaluateEngageCharacter
MissionEvaluateEngageFaction
MissionEvaluateGainMilitaryAccess
MissionEvaluateMakeAlliance
MissionEvaluateMakeTradeAgreement
MissionEvaluateRecruit
MissionEvaluateResearch
MissionEvaluateSpyOnCity
MissionFailed
MissionIssued
MissionNearingExpiry
MissionSucceeded
MovementPointsExhausted
MultiTurnMove
NewSession
PanelAdviceRequestedBattle
PanelAdviceRequestedCampaign
PanelClosedBattle
PanelClosedCampaign
PanelOpenedBattle
PanelOpenedCampaign
PreBattle
RecruitmentItemIssuedByPlayer
RegionIssuesDemands
RegionRebels
RegionRiots
RegionTurnEnd
RegionTurnStart
ResearchCompleted
SabotageAttemptSuccess
SavingGame
SeaTradeRouteRaided
SettlementOccupied
SettlementSelected
SiegeLifted
SlotOccupied
SlotOpens
SlotRoundStart
SlotSelected
SlotTurnStart
SpyingAttemptSuccess
SufferAssassinationAttempt
SufferSpyingAttempt
TechnologyInfoPanelOpenedCampaign
TimeTrigger
TooltipAdvice
TradeLinkEstablished
TradeRouteEstablished
UICreated
UIDestroyed
UngarrisonedFort
UnitCompletedBattle
UnitCreated
UnitSelectedCampaign
UnitTrained
UnitTurnEnd
VictoryConditionFailed
VictoryConditionMet
WorldCreated
_M
_NAME
_PACKAGE
evaluate_mission
historical_events
n
```

## `data` - 5 entries

```
events
export_ancillaries
export_historic_characters
export_missions
export_triggers
```


---

# PART 2 - CAMPAIGN: modules and the WRITE API

*Enumerated live 2026-09-18 18:50.*

`require` works from ESE eval, and `package.loaded` lists every module:

```
CoreUtils, EpisodicScripting, Utilities, _G, agents, army, bit, construction, coroutine, data.events, data.export_ancillaries, data.export_historic_characters, data.export_missions, data.export_triggers, debug, export_advice, export_historic_events, huds, io, labels, math, message_handler, os, package, panelmanager, recruitment, siegeequipment, string, table, utilities
```

## `EpisodicScripting.game_interface` - THE WRITE API

`require 'EpisodicScripting'` -> `.game_interface` (userdata). Methods live
directly ON THE METATABLE (there is no `__index` table), so enumerate with
`pairs(getmetatable(gi))`. Call as `gi:method(...)`.

```
add_attack_of_opportunity_overrides
add_building_model_override
add_custom_battlefield
add_exclusion_zone
add_location_trigger
add_restricted_building_level_record
add_restricted_unit_record
add_settlement_model_override
add_time_trigger
add_unit_model_overrides
add_visibility_trigger
advance_to_next_campaign
award_experience_level
cancel_actions_for
compare_localised_string
declare_episode_one_victory
declare_episode_three_victory
declare_episode_two_victory
disable_elections
disable_movement_for_ai_under_shroud
disable_movement_for_character
disable_movement_for_faction
disable_shopping_for_ai_under_shroud
disable_town_spawning
display_turns
enable_auto_generated_missions
enable_ui
episodic_attack
episodic_defend
force_diplomacy
get_string_label
grant_faction_handover
is_new_game
load_value
new
optional_extras_for_episodics
register_instant_movie
register_movies
remove_attack_of_opportunity_overrides
remove_barrier
remove_building_model_override
remove_custom_battlefield
remove_location_trigger
remove_restricted_building_level_record
remove_restricted_unit_record
remove_settlement_model_override
remove_time_trigger
remove_visibility_trigger
save_value
set_campaign_ai_force_all_factions_boardering_human_protectorates_to_have_invasion_behaviour
set_campaign_ai_force_all_factions_boardering_humans_to_have_invasion_behaviour
set_map_bounds
set_zoom_limit
show_shroud
spawn_town_level
stop_user_input
technology_osmosis_for_playables_enable_all
technology_osmosis_for_playables_enable_culture
trigger_custom_mission
unveil_black_shroud
```

### Most significant for this project

- **`save_value` / `load_value`** - native persistence, almost certainly stored
  IN THE SAVE GAME. The mod currently persists state through text files
  (`trade_sim_state.txt`) with all the encoding/path fragility that caused
  real outages. This is the supported mechanism.
- **`add_time_trigger` / `remove_time_trigger`** - scheduled callbacks instead
  of doing everything inside FactionTurnStart.
- **`add_restricted_unit_record` / `add_restricted_building_level_record`** -
  restrict what a faction may recruit or build. A real lever for embargo/
  scarcity mechanics, enforced by the engine rather than simulated.
- `force_diplomacy`, `trigger_custom_mission` - already used by this project.
- `disable_movement_for_character` / `_for_faction`, `cancel_actions_for`.
- `set_campaign_ai_force_all_factions_boardering_humans_to_have_invasion_behaviour`
  (sic) - direct campaign-AI behaviour control.
- `add_location_trigger` / `add_visibility_trigger`, `award_experience_level`,
  `grant_faction_handover`, `spawn_town_level`, `get_string_label`.

## Notable modules

- **`agents`** - `RakeAssassinate`, `RakeSubterfuge`, `ResearcherSteal`,
  `GentlemanDuel`. NOTE: this contradicts the earlier project conclusion that
  no agent system exists in this install. These are UI-side entry points, but
  the actions are real.
- `army` (44 fns), `construction` (28), `recruitment` (17) - UI panel layer.
- `Utilities` - engine enums: `SPYING_DATA_LEVEL_*`, `TECHNOLOGY_STATUS_*`,
  `CT_*` commander types.
- `CoreUtils` - `PrintTable`, `SaveTable`/`LoadTable`, `CopyTable`, `Clamp`.

---

# PART 3 - BATTLE: 208 natives

The battle `lua_State` is a **different state** with a **completely different
surface**: none of `conditions`, `effect` or `events` exists here. Reach it with

```powershell
.\ese.ps1 "@battle return BattleDetails()"
```

Three properties of this state cost real time to learn:

- **It is rebuilt for every battle**, wiping all globals. Anything you install
  must be re-installed per battle (`empire.ps1 arm`), and a tick that calls a
  now-nil function keeps reporting healthy because `pcall` swallows it.
- **These natives are resolved lazily and are NOT stored as globals.** Probing
  `type(CameraZoomTo)` returns `nil` even in a live battle where the call works,
  so you cannot use a global lookup to detect the battle state or to verify a
  name exists. Call it, or trace its address.
- **8 addresses are shared by more than one name** (aliases, e.g.
  `00455F60` serves three). A trace on one address therefore fires for every
  alias of it.

Addresses are **static**, image base `0x400000`, from this 1.5.0.0 build. To use
one against the running process, translate it through the ASLR bridge (`base +
delta`); ESE prints `delta` at startup. Prefer `ESE_Scan` on a byte pattern if
you need it to survive a different build.

## Documented (119 of 208)

| name | addr | what it does |
|---|---|---|
| `AddUnitsToGroup` | `005F51E0` | Takes a table of unit addresses, and a group id and adds the units to the group specified |
| `BattleDetails` | `005F52D0` | Get some details about the battle. For the time being this is whether it is a naval battle, and the players faction details |
| `CameraFocusOnSelection` | `005F5890` | Takes the address of a unit. Zooms the camera over to look at the unit specified. Doesn't currently work in naval battles |
| `CameraZoomTo` | `005F5B30` | In: Position (x,y,z), facing |
| `CameraZoomToSelection` | `005F5C40` | Takes the address of a unit. Zooms the camera over to look at the unit specified. Doesn't currently work in naval battles |
| `CancelOrderForSelection` | `005F5DF0` | Cancel order for selected units |
| `ChangeAdviceMode` | `005F5EB0` | Repeat the current advice on the c++ side |
| `ClearDeployableItemsPanel` | `005F5F50` | checks if a unit is selectable |
| `CreateUnitGroup` | `005F6070` | Takes a table of unit address to build a group from, returns the id of the new group |
| `Current_Radar_Screen_Positioning` | `005F62C0` | Init radar positioning |
| `Current_Selection_Enable_Deploy_Stakes` | `005F64F0` | Currently selected units deploy stakes |
| `Current_Selection_Enable_Fire_And_Advance` | `005F6600` | Currently selected units enable/disable the fire and advance order. Takes true or false. |
| `Current_Selection_Enable_Improved_Grenades` | `005F67C0` | Currently selected units select improved grenades. Takes true or false. |
| `Current_Selection_Enable_Percussive_Shell` | `005F6990` | Currently selected units enable/disable percussive shells. Takes true or false. |
| `Current_Selection_Enable_Ring_Bayonets` | `005F6970` | Currently selected units enable/disable ring bayonets. Takes true or false. |
| `Current_Selection_Enable_Spike` | `005F6970` | Currently selected units perform the spike order |
| `CycleBattleSpeed` | `005F71A0` | Returns the current time multiplier of the battle |
| `DeploymentFinishYesStart` | `005F7370` | Returns true if we're in conflict mode |
| `DestroyUnitGroup` | `005F73A0` | Takes the id of a unit group as returned by the create function and removes it from the game |
| `DisableChevaux` | `005F74B0` | DisableChevaux |
| `DisableEarthworks` | `005F74C0` | Retrieve the current width and height of the screen |
| `DisableFougasse` | `005F74D0` | Retrieve the current width and height of the screen |
| `DisableFougasseImproved` | `005F74E0` | Retrieve the current width and height of the screen |
| `DisableGabionade` | `005F74F0` | DisableGabionade |
| `DismissCurrentAdvice` | `005F7500` | Dismisses the current advice on the c++ side |
| `Drag_Radar` | `005F76A0` | Drag radar |
| `ElapsedBattleTime` | `005F7760` | Returns the current time in seconds |
| `EnableChevaux` | `005F7790` | EnableChevaux |
| `EnableEarthworks` | `005F77A0` | Retrieve the current width and height of the screen |
| `EnableFougasse` | `005F77B0` | Retrieve the current width and height of the screen |
| `EnableFougasseImproved` | `005F77C0` | Retrieve the current width and height of the screen |
| `EnableGabionade` | `005F77D0` | EnableGabionade |
| `EnableShortcutHandler` | `005F77E0` | In: true/false to enable/disable all keyboard shortcuts |
| `EnableVoiceChat` | `005F7820` | In: true/false to start/stop voice chat |
| `EnumerateBattleReplays` | `005F7880` | In: replay directory, file extention. Out: Table of details about each replay file found in the directory |
| `ExitBattle` | `005F78C0` | set to normal tick speed and finishes the battle |
| `ExplicitlyCancelMouseHeld` | `005F78D0` | forces to UI to think the mouse left button is no longer held. Used when a panel is open that takes focus |
| `FileExtenstionAndPathForWriteClass` | `005F7910` | In: string identifying OSFS_WRITECLASS. Out: File extension used by that class, directory files are kept in |
| `FindImagePath` | `005F7B90` | Tells us what the currently selected Ui skin is (which should equate to the sub-folder used |
| `GetHealthStatus` | `005F7DC0` | Update the killometer bar |
| `HasEnteredDeployment` | `005F7E20` | Returns true if we're in deployment (not default deployment) mode |
| `InformAdviceReachedRender` | `005F7F20` | repeat the curently played advice |
| `InformOfBattleSummaryDismiss` | `005F7F50` | local player has dismissed the summary |
| `InformOfDeploymentCountdownBegun` | `005F7F60` | local player has dismissed the summary |
| `InformOfDeploymentFinished` | `005F7F90` | local player has dismissed the summary |
| `Init_Radar` | `005F7FA0` | Init radar |
| `IsAudioPlaying` | `005F82A0` | repeat the curently played advice |
| `IsConflict` | `005F82E0` | Returns true if we're in conflict mode |
| `IsDeploymentOrConflict` | `005F8320` | Returns true if we're in conflict mode |
| `IsMinimisedHUD` | `005F8390` | If it's minimised HUD |
| `IsMultiplayer` | `005F8430` | Out: True if this is a multiplayer battle |
| `IsReplay` | `005F8470` | If it's a replay |
| `IsSpectator` | `005F84B0` | If it's a spectator |
| `IsTutorial` | `005F8510` | Out: true if we are running a tutorial battle |
| `IsUnitSelectable` | `005F8540` | checks if a unit is selectable |
| `LocalisationString` | `005F8760` | Retrieve a string from the random localisation strings table |
| `MouseMovedOffCard` | `005F8AD0` | Notify the game that unit selection has changed |
| `MouseMovedOntoCard` | `005F8AF0` | Notify the game that mouse has moved over this card |
| `Move_Camera` | `005F8B60` | Move Camera |
| `Move_Selection_To_Rader_Location` | `005F8CF0` | Move Camera |
| `MPOnlinePresence` | `005F8840` | Out: Pointer to the online presence that exists in game core |
| `MPRematchVotes` | `005F8880` | Gets the current number of votes to have a rematch |
| `MPRestartPossible` | `005F88C0` | If someone left the lobby then we can't restart |
| `MPRestartSwappedPossible` | `005F8900` | If someone left the lobby then we can't restart |
| `MPResultsReady` | `005F8940` | Checks to see if the MP battle results have been collected |
| `MPSkillRating` | `005F8990` | Gets the players rating |
| `MPSwapVotes` | `005F89F0` | Gets the current number of votes to swap sides |
| `MPVoteRestart` | `005F8A30` | Player votes |
| `MPVotingComplete` | `005F8A60` | Checks for everyone having voted |
| `MultiplayerBaseInterface` | `005F8DA0` | Out: Pointer to the multiplayer control module (to be passed to UIMPInterface object |
| `NextAvailableGroupID` | `005F8DE0` | Takes the id of a unit group as returned by the create function and removes it from the game |
| `NotifyCameraControlsChanged` | `005F8E70` | this is for lua to change the camera (key controls handled by shortcut handler |
| `NotifyUIOptionsChanged` | `005F8E90` | this is for lua to change the camera (key controls handled by shortcut handler |
| `NumHumansRequestingNextPhase` | `005F9060` | the number of Human players Requesting Next battle Phase |
| `Percentage_Of_Time_Passed` | `005F90C0` | Percentage Of Time Passed |
| `PostBattleDismissContinueBattle` | `005F9140` | local player has dismissed the summary |
| `PostBattleDismissEndBattle` | `005F9150` | local player has dismissed the summary |
| `PostBattleInfo` | `005F9160` | Fetches the post battle info from the game and Alexs' MP API |
| `Register_Faction_Colours` | `005FB150` | Register Faction Colours |
| `Register_Land_Radar_Handles` | `005FB400` | Register Land Radar Handles |
| `Register_Naval_Radar_Handles` | `005FB710` | Register Naval Radar Handles |
| `RemainingTimeToDrop` | `005FB900` | Out: True if this is a multiplayer battle |
| `RemoveUnitsFromGroup` | `005FB950` | Takes a table of unit addresses, and removes the units from the group they are in |
| `RepeatAdvice` | `005FBA40` | repeat the curently played advice |
| `RetrieveGameCore` | `005FBA80` | Out: Returns pointers to the game core so that a UIPrefsInterface object can be initialised |
| `SaveReplay` | `005FBAC0` | In: battle replay file name |
| `ScreenSize` | `005FBC20` | Retrieve the current width and height of the screen |
| `SelectAllArtillery` | `005FBC80` | select units of this type |
| `SelectAllCavalry` | `005FBCA0` | select units of this type |
| `SelectAllInfantry` | `005FBCC0` | select units of this type |
| `SelectAllMelee` | `005FBCE0` | select units of this type |
| `SelectionChanged` | `005FBDB0` | Notify the game that unit selection has changed |
| `SelectUnitBasedOnUnitType` | `005FBD00` | Change the selection based on a unit class |
| `SetSelectionProxy` | `005FBDD0` | Takes the address of the entity (ship/unit) and a boolean flag and sets the proxy display for that entity as appropriate |
| `SquadInfoByPointer` | `005FC280` | Notify the game that mouse has moved over this card |
| `TickPeriod` | `005FC3B0` | Returns the current time multiplier of the battle |
| `Time` | `005FC4C0` | Returns the current time in seconds |
| `ToggleMinimisedCards` | `005FC500` | Toggles cards on and off |
| `ToggleMinimisedOrders` | `005FC550` | Toggles orders on and off |
| `ToggleMinimisedRadar` | `005FC5A0` | Toggles radar on and off |
| `ToggleMusic` | `005FC5F0` | Toggles Music on and off |
| `ToggleSFX` | `005FC650` | Toggles SFX on and off |
| `ToggleShipFiringArcs` | `005FC6E0` | Toggle the display of ship firing arcs |
| `TriggerAdviceForPanel` | `005FC6F0` | In: Name of panel |
| `TriggerMessageDropEvent` | `005FC7C0` | Plays the sound that occurs when a message hits the bottom of the msg stack |
| `TriggerMessageOpenedEvent` | `005FC850` | In: Message id |
| `TriggerPanelClosedEvent` | `005FC920` | In: Name of panel |
| `TriggerPanelOpenEvent` | `005FCA10` | In: Name of panel |
| `UILocalisationString` | `0046D170` | Retrieve a string from the ui.loc file |
| `UISkin` | `005FCD70` | Tells us what the currently selected Ui skin is (which should equate to the sub-folder used |
| `UnitScaleFactor` | `005FCDA0` | In: (Opt) current scale factor, Out: float value representing current unit scale, index into scale factors list : 0-3 |
| `Update_Land_Radar` | `005FCE40` | Update land radar |
| `Update_Naval_Radar` | `005FD610` | Update naval radar |
| `Update_Radar_Zoom_Level` | `005FDB30` | Update radar |
| `Valid` | `005FDC20` | Is the UI open |
| `WindDirection` | `005FDC50` | Update the wind pointer |
| `ZoomToAdviceLocation` | `005FDCB0` | Moves the camera the current advice on the c++ side |
| `ZoomToGeneral` | `005FDCC0` | checks if a unit is selectable |
| `ZoomToUnit` | `005FDDE0` | Zoom the camera over to a particular unit |

## Undocumented (89 of 208)

Name and address only - the dump carried no description. Behaviour is
unknown until traced or called; treat every one as `[?]`.

| name | addr | name | addr |
|---|---|---|---|
| `Anchor` | `005F52B0` | `BattleEditorPause` | `00455F60` |
| `BattleEditorUnpause` | `00455F60` | `BattleEditorVisibleState` | `005F54C0` |
| `Board` | `005F54E0` | `Broadside_Left_Issue_Order` | `005F5640` |
| `Broadside_Right_Issue_Order` | `005F5660` | `Broadside_Update` | `005F5680` |
| `BroadsideMouseEvent` | `005F5520` | `Column_Infantry_Vanguard` | `005F5FB0` |
| `Crescent_Attack` | `005F6140` | `Crescent_Envelop` | `005F6200` |
| `Current_Selection_Detonate_Fougasse_Basic` | `005F6410` | `Current_Selection_Detonate_Fougasse_Improved` | `005F6430` |
| `Current_Selection_Enable_Canister_Shottype` | `005F6450` | `Current_Selection_Enable_Carcass_Shottype` | `005F64A0` |
| `Current_Selection_Enable_Diamond_Formation` | `005F6510` | `Current_Selection_Enable_Dismount` | `005F6560` |
| `Current_Selection_Enable_Explosive_Shell` | `005F65B0` | `Current_Selection_Enable_Fire_At_Will` | `005F6650` |
| `Current_Selection_Enable_Grenade_Shottype` | `005F66D0` | `Current_Selection_Enable_Guard` | `005F6720` |
| `Current_Selection_Enable_Hot_Shottype` | `005F6770` | `Current_Selection_Enable_Light_Infantry_Behaviour` | `005F6810` |
| `Current_Selection_Enable_Limber` | `005F6860` | `Current_Selection_Enable_Loose_Formation` | `005F68B0` |
| `Current_Selection_Enable_Melee` | `005F6900` | `Current_Selection_Enable_Melee_Formation` | `005F6970` |
| `Current_Selection_Enable_Pike_Square_Formation` | `005F69D0` | `Current_Selection_Enable_Pike_Wall_Formation` | `005F6A20` |
| `Current_Selection_Enable_Plug_Bayonets` | `005F6A70` | `Current_Selection_Enable_Prone_Formation` | `005F6AC0` |
| `Current_Selection_Enable_Quicklime_Shottype` | `005F6B10` | `Current_Selection_Enable_Rockets_Shottype` | `005F6B60` |
| `Current_Selection_Enable_Shot_Shottype` | `005F6BB0` | `Current_Selection_Enable_Shrapnel_Shottype` | `005F6C00` |
| `Current_Selection_Enable_Skirmish` | `005F6C50` | `Current_Selection_Enable_Square_Formation` | `005F6CA0` |
| `Current_Selection_Enable_Wedge_Formation` | `005F6CF0` | `Current_Selection_Halt` | `005F52B0` |
| `Current_Selection_Increase_File` | `005F6D40` | `Current_Selection_Increase_File_Proxy` | `005F6D80` |
| `Current_Selection_Increase_Rank` | `005F6D90` | `Current_Selection_Increase_Rank_Proxy` | `005F6DC0` |
| `Current_Selection_Move_Backwards` | `005F6DD0` | `Current_Selection_Move_Backwards_Proxy` | `005F6E00` |
| `Current_Selection_Move_Forwards` | `005F6E40` | `Current_Selection_Move_Forwards_Proxy` | `005F6E00` |
| `Current_Selection_Proxy_Rotate_Left` | `005F6E90` | `Current_Selection_Proxy_Rotate_Right` | `005F6EE0` |
| `Current_Selection_Proxy_Turn_Left` | `005F6E90` | `Current_Selection_Proxy_Turn_Right` | `005F6EE0` |
| `Current_Selection_Rotate_Left` | `005F6F30` | `Current_Selection_Rotate_Right` | `005F6FC0` |
| `Current_Selection_Runs` | `005F7050` | `Current_Selection_Special_ability` | `00455F60` |
| `Current_Selection_Turn_Left` | `005F7070` | `Current_Selection_Turn_Right` | `005F70F0` |
| `Current_Selection_Walks` | `005F7180` | `Decrease_Sail` | `005F72B0` |
| `Double_Line_Screened` | `005F7520` | `Double_Line_Standard` | `005F75E0` |
| `Ffwd` | `005F78F0` | `Fire_At_Will` | `005F7D50` |
| `Fwd` | `005F7DA0` | `Go_Straight` | `005F7E00` |
| `Increase_Sail` | `005F7E60` | `IsTimedMultiplayerGame` | `005F8430` |
| `Land_Unit_Withdraw` | `005F85C0` | `Line_Abreast` | `005F85E0` |
| `Line_Astern` | `005F86A0` | `Naval_Unit_Withdraw` | `005F85C0` |
| `Pause` | `005F90A0` | `Play` | `005F9120` |
| `Ram` | `005FB130` | `Repair` | `005FBA10` |
| `Repel` | `005FBA60` | `Shot_Chain` | `005FBFC0` |
| `Shot_Grape` | `005FBFE0` | `Shot_Waterline` | `005FC000` |
| `show_allied_units_proxies` | `005FDF30` | `Single_Line_Cavalry_Left_Flank` | `005FC020` |
| `Single_Line_Cavalry_Right_Flank` | `005FC0E0` | `Single_Line_Standard` | `005FC1A0` |
| `Slow` | `005FC260` | `Stop_Rotating_Rendering` | `005FC390` |
| `Triple_Line_Grand_Battery` | `005FCB30` | `Triple_Line_Integrated_Artillery` | `005FCBF0` |
| `Triple_Line_Standard` | `005FCCB0` |  | |

---

# PART 4 - corrections to earlier claims

Kept in the same file as the claims they correct, so nobody reads one without
the other.

- **`add_restricted_unit_record` does NOT work.** It is listed in Part 2 because
  it IS on the `game_interface` metatable - and a live call disproved it anyway.
  **Metatable presence is necessary, not sufficient.** Enforce recruitment
  scarcity with a native hook or `effect.adjust_treasury` instead. The same
  caution applies to every other Part 2 name that has not been called.
- **The `agents` module contradicts "this install has no agent system."**
  `RakeAssassinate`, `RakeSubterfuge`, `ResearcherSteal`, `GentlemanDuel` are
  real entry points, though UI-side.
- **`pcall` does not protect a native call.** These functions are C that
  dereference arguments without validating them, so a bad argument is an access
  violation, not a catchable Lua error. Wrong *arity* crashed a campaign once;
  the key and scope were fine.
- **Wrong `context` scope returns silent zeros**, not an error: faction
  conditions under a `SettlementSelected` context report `TurnNumber=0`,
  `FactionTreasury=0`. Call inside a handler of matching scope; never store a
  context for later.

See `REVIEW_SECURITY_AND_MODDING.md` for the wider list of what does not work,
and `FPS_MOD_API_TREE.md` for the battle *object graph* that these natives act
on (entities, units, camera, terrain).

