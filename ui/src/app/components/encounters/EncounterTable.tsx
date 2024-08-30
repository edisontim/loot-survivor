import {
  BladeIcon,
  BludgeonIcon,
  ClothIcon,
  CoinIcon,
  HeartVitalityIcon,
  HideIcon,
  MagicIcon,
  MetalIcon,
  InfoIcon,
  DownArrowIcon,
} from "@/app/components/icons/Icons";
import LootIcon from "@/app/components/icons/LootIcon";
import React, { useMemo, useState } from "react";
import useAdventurerStore from "@/app/hooks/useAdventurerStore";
import { useQueriesStore } from "@/app/hooks/useQueryStore";
import useUIStore from "@/app/hooks/useUIStore";
import { vitalityIncrease } from "@/app/lib/constants";
import { GameData } from "@/app/lib/data/GameData";
import { calculateLevel, getItemData } from "@/app/lib/utils";
import {
  getDecisionTree,
  getOutcomesWithPath,
  listAllEncounters,
  Step,
} from "@/app/lib/utils/processFutures";
import Draggable from "react-draggable";
import { MdClose } from "react-icons/md";

const EncounterTable = () => {
  const adventurer = useAdventurerStore((state) => state.adventurer);
  const adventurerEntropy = useUIStore((state) => state.adventurerEntropy);
  const showEncounterTable = useUIStore((state) => state.showEncounterTable);
  const hasBeast = useAdventurerStore((state) => state.computed.hasBeast);

  const [hoveredBeast, setHoveredBeast] = useState<number | null>(null);

  const formattedAdventurerEntropy = BigInt(adventurerEntropy);
  const purchaseItems = useUIStore((state) => state.purchaseItems);
  const potionAmount = useUIStore((state) => state.potionAmount);
  const upgrades = useUIStore((state) => state.upgrades);

  const { data } = useQueriesStore();

  let gameData = new GameData();

  const purchaseItemsObjects = purchaseItems
    .filter((item) => item.equip)
    .map((item) => {
      const itemName = gameData.ITEMS[Number(item.item)];
      return getItemData(itemName);
    });

  let armoritems =
    data.itemsByAdventurerQuery?.items
      .map((item) => ({ ...item, ...getItemData(item.item ?? "") }))
      .filter((item) => {
        return !["Weapon", "Ring", "Neck"].includes(item.slot!);
      }) || [];

  let weaponItems =
    data.itemsByAdventurerQuery?.items
      .map((item) => ({ ...item, ...getItemData(item.item ?? "") }))
      .filter((item) => {
        return item.slot! === "Weapon";
      }) || [];

  const items = useMemo(() => {
    let equippedItems =
      data.itemsByAdventurerQuery?.items
        .filter((item) => item.equipped)
        .map((item) => ({
          item: item.item,
          ...getItemData(item.item ?? ""),
          special2: item.special2,
          special3: item.special3,
          xp: Math.max(1, item.xp!),
        })) || [];

    let updatedItems = equippedItems.map((item: any) => {
      const purchaseItem = purchaseItemsObjects.find(
        (purchaseItem) => purchaseItem.slot === item.slot
      );
      if (purchaseItem) {
        return {
          ...purchaseItem,
          special2: undefined,
          special3: undefined,
          xp: 1, // Default XP for new items
        };
      }
      return item;
    });

    // Add any new items from purchaseItemsObjects that weren't replacements
    purchaseItemsObjects.forEach((purchaseItem) => {
      if (!updatedItems.some((item: any) => item.slot === purchaseItem.slot)) {
        updatedItems.push({
          ...purchaseItem,
          special2: undefined,
          special3: undefined,
          xp: 1, // Default XP for new items
        });
      }
    });

    return updatedItems;
  }, [data.itemsByAdventurerQuery?.items, purchaseItemsObjects]);

  const updatedAdventurer = useMemo(() => {
    if (!adventurer) return null;

    let newAdventurer = { ...adventurer };

    if (upgrades.Strength > 0) {
      newAdventurer.strength! += upgrades.Strength;
    }
    if (upgrades.Dexterity > 0) {
      newAdventurer.dexterity! += upgrades.Dexterity;
    }
    if (upgrades.Vitality > 0) {
      newAdventurer.vitality =
        Number(newAdventurer.vitality) + upgrades.Vitality;
      newAdventurer.health =
        newAdventurer.health! + upgrades.Vitality! * vitalityIncrease;
    }
    if (upgrades.Intelligence > 0) {
      newAdventurer.intelligence! += upgrades.Intelligence;
    }
    if (upgrades.Wisdom > 0) {
      newAdventurer.wisdom! += upgrades.Wisdom;
    }
    if (upgrades.Charisma > 0) {
      newAdventurer.charisma! += upgrades.Charisma;
    }

    // Apply purchased potions
    if (potionAmount > 0) {
      newAdventurer.health = Math.min(
        newAdventurer.health! + potionAmount * 10,
        100 + newAdventurer.vitality! * vitalityIncrease
      );
    }

    return newAdventurer;
  }, [
    adventurer,
    potionAmount,
    upgrades.Charisma,
    upgrades.Intelligence,
    upgrades.Strength,
    upgrades.Wisdom,
    upgrades.Vitality,
    upgrades.Dexterity,
  ]);

  const encounters = useMemo(
    () =>
      listAllEncounters(
        updatedAdventurer?.xp!,
        formattedAdventurerEntropy,
        hasBeast,
        updatedAdventurer?.level!
      ),
    [updatedAdventurer?.xp, formattedAdventurerEntropy]
  );

  const outcomesWithPath = useMemo(() => {
    if (!updatedAdventurer || !items) return [];
    const decisionTree = getDecisionTree(
      updatedAdventurer!,
      items,
      formattedAdventurerEntropy,
      hasBeast,
      updatedAdventurer?.level!
    );
    return getOutcomesWithPath(decisionTree).sort(
      (a, b) =>
        b[b.length - 1].adventurer.health! - a[a.length - 1].adventurer.health!
    );
  }, [updatedAdventurer?.xp, formattedAdventurerEntropy, items]);

  return (
    <Draggable>
      <div className="flex flex-col gap-5 sm:gap-0 sm:flex-row justify-between w-full bg-terminal-black max-h-[300px] overflow-y-auto border border-terminal-green text-xs sm:text-base">
        <div className="h-full">
          <div className="flex flex-col w-full flex-grow-2">
            <div className="flex w-full justify-center h-8"></div>
            <button
              className="absolute top-0 right-0"
              onClick={() => showEncounterTable(false)}
            >
              <MdClose className="w-10 h-10" />
            </button>

            <table className="border-separate border-spacing-0 w-full sm:text-sm xl:text-sm 2xl:text-sm block overflow-x-scroll sm:overflow-y-scroll default-scroll p-2">
              <thead
                className="border border-terminal-green sticky top-0 bg-terminal-black uppercase"
                style={{ zIndex: 8 }}
              >
                <tr className="border border-terminal-green">
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    XP (lvl)
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Encounter
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Tier
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Lvl
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    HP
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Type
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Location
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Avoid
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Crit
                  </th>
                  <th className="py-2 px-1 border-b border-terminal-green">
                    Next XP (Lvl)
                  </th>
                  <th className="py-2 px-1 border-b border-terminal-green">
                    Gold
                  </th>
                </tr>
              </thead>
              <tbody>
                {adventurerEntropy ? (
                  React.Children.toArray(
                    encounters.map((encounter: any, index: number) => {
                      let [special2, special3] = encounter.specialName?.split(
                        " "
                      ) || ["no", "no"];
                      let nameMatch =
                        encounter.encounter === "Beast" && encounter.level >= 19
                          ? armoritems.find(
                              (item) =>
                                item.special2 === special2 ||
                                item.special3 === special3
                            )
                          : false;
                      let weaponMatch =
                        encounter.encounter === "Beast" && encounter.level >= 19
                          ? weaponItems.find(
                              (item) =>
                                item.special2 === special2 ||
                                item.special3 === special3
                            )
                          : false;

                      return (
                        <tr className="">
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex">
                              {encounter.xp}. ({encounter.adventurerLevel})
                            </span>
                          </td>
                          <td
                            className={`py-2 border-b border-terminal-green tooltip flex flex-row gap-1 ${
                              nameMatch
                                ? "text-red-500"
                                : weaponMatch
                                ? "text-green-500"
                                : "text-terminal-yellow"
                            }`}
                          >
                            <span className="uppercase">
                              {encounter.encounter}
                            </span>
                            {encounter.encounter === "Beast" &&
                              encounter.level >= 19 && (
                                <span className="tooltiptext bottom">
                                  {encounter.specialName}
                                </span>
                              )}
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.encounter !== "Discovery" &&
                                encounter.tier}
                              {encounter.type === "Health" && (
                                <div className="flex items-center">
                                  {" "}
                                  {encounter.tier}{" "}
                                  <HeartVitalityIcon className="h-3 pl-0.5" />
                                </div>
                              )}
                              {encounter.type === "Gold" && (
                                <div className="flex items-center">
                                  {" "}
                                  {encounter.tier}{" "}
                                  <CoinIcon className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow" />
                                </div>
                              )}
                              {encounter.type === "Loot" && (
                                <div className="flex items-center">
                                  {" "}
                                  {gameData.ITEMS[encounter.tier]}{" "}
                                  <LootIcon
                                    type={
                                      gameData.ITEM_SLOTS[
                                        gameData.ITEMS[encounter.tier].replace(
                                          /\s+/g,
                                          ""
                                        )
                                      ]
                                    }
                                    className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow"
                                  />
                                </div>
                              )}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.level}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.health}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center gap-1 items-center">
                              {encounter.type === "Blade" && (
                                <BladeIcon className="h-4" />
                              )}
                              {encounter.type === "Bludgeon" && (
                                <BludgeonIcon className="h-4" />
                              )}
                              {encounter.type === "Magic" && (
                                <MagicIcon className="h-4" />
                              )}

                              {encounter.encounter === "Beast" && (
                                <>
                                  <span>/</span>
                                  {encounter.type === "Blade" && (
                                    <HideIcon className="h-4" />
                                  )}
                                  {encounter.type === "Bludgeon" && (
                                    <MetalIcon className="h-4" />
                                  )}
                                  {encounter.type === "Magic" && (
                                    <ClothIcon className="h-4" />
                                  )}
                                </>
                              )}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.location}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex items-center gap-1">
                              <span className="uppercase">
                                {encounter.dodgeRoll &&
                                (encounter.encounter === "Beast"
                                  ? updatedAdventurer?.wisdom!
                                  : updatedAdventurer?.intelligence!) >=
                                  encounter.dodgeRoll
                                  ? "Yes"
                                  : "No"}
                              </span>
                              <span className="flex justify-center">
                                {encounter.dodgeRoll &&
                                  `(${encounter.dodgeRoll})`}
                              </span>
                            </span>
                          </td>
                          <td
                            className={`py-2 border-b border-terminal-green ${
                              encounter.criticalMultiplier > 3
                                ? "text-red-500"
                                : encounter.criticalMultiplier > 0
                                ? "text-terminal-yellow"
                                : ""
                            }`}
                          >
                            {encounter.criticalMultiplier >= 0 && (
                              <span className="flex justify-center">
                                {encounter.criticalMultiplier > 0
                                  ? `${encounter.criticalMultiplier * 20}%`
                                  : "No"}
                              </span>
                            )}
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center text-terminal-yellow">
                              {encounter.nextXp} (
                              {calculateLevel(encounter.nextXp)})
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            {encounter.encounter === "Beast" && (
                              <span className="flex justify-center">
                                +
                                {Math.floor(
                                  (encounter.level * (6 - encounter.tier)) / 2
                                )}
                              </span>
                            )}
                          </td>
                        </tr>
                      );
                    })
                  )
                ) : (
                  <tr className="flex items-center h-10 absolute">
                    <span className="p-4">Waiting for new entropy...</span>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          {updatedAdventurer?.entropy &&
            outcomesWithPath.map((steps: Step[]) => (
              <React.Fragment>
                Path {steps.map((step) => step.previousDecision).join(" -> ")}
                <table className="border-separate border-spacing-0 w-full sm:text-sm xl:text-sm 2xl:text-sm block overflow-x-scroll sm:overflow-y-scroll default-scroll p-2">
                  <thead
                    className="border border-terminal-green sticky top-0 bg-terminal-black uppercase"
                    style={{ zIndex: 8 }}
                  >
                    <tr className="border border-terminal-green">
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        XP (lvl)
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Encounter
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Tier
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Lvl
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        HP
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Type
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Location
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Avoid
                      </th>
                      <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                        Crit
                      </th>
                      <th className="py-2 px-1 border-b border-terminal-green">
                        Next XP (Lvl)
                      </th>
                      <th className="py-2 px-1 border-b border-terminal-green">
                        Ambush
                      </th>
                      <th className="py-2 px-1 border-b border-terminal-green">
                        Gold
                      </th>
                      <th className="py-2 px-1 border-b border-terminal-green">
                        Health after
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {adventurerEntropy ? (
                      React.Children.toArray(
                        steps.map(({ encounter, adventurer }, index) => {
                          if (!encounter && adventurer.health! <= 0) {
                            return <tr>Death</tr>;
                          }
                          const nextAdventurerState =
                            steps[index + 1]?.adventurer || adventurer;
                          if (!encounter) {
                            return <tr>Level up</tr>;
                          }
                          let [special2, special3] =
                            encounter.specialName?.split(" ") || ["no", "no"];
                          let nameMatch =
                            encounter.encounter === "Beast" &&
                            encounter.level! >= 19
                              ? armoritems.find(
                                  (item) =>
                                    item.special2 === special2 ||
                                    item.special3 === special3
                                )
                              : false;
                          let weaponMatch =
                            encounter.encounter === "Beast" &&
                            encounter.level! >= 19
                              ? weaponItems.find(
                                  (item) =>
                                    item.special2 === special2 ||
                                    item.special3 === special3
                                )
                              : false;

                          return (
                            <tr className="">
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex">
                                  {encounter.xp}. ({adventurer.level!})
                                </span>
                              </td>
                              <td
                                className={`py-2 border-b border-terminal-green tooltip flex flex-row gap-1 ${
                                  nameMatch
                                    ? "text-red-500"
                                    : weaponMatch
                                    ? "text-green-500"
                                    : "text-terminal-yellow"
                                }`}
                              >
                                <span className="uppercase">
                                  {encounter.encounter}
                                </span>
                                {encounter.encounter === "Beast" &&
                                  adventurer.level! >= 19 && (
                                    <span className="tooltiptext bottom">
                                      {encounter.specialName}
                                    </span>
                                  )}
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {encounter.encounter !== "Discovery" &&
                                    encounter.tier}
                                  {encounter.type === "Health" && (
                                    <div className="flex items-center">
                                      {" "}
                                      {encounter.tier}{" "}
                                      <HeartVitalityIcon className="h-3 pl-0.5" />
                                    </div>
                                  )}
                                  {encounter.type === "Gold" && (
                                    <div className="flex items-center">
                                      {" "}
                                      {encounter.tier}{" "}
                                      <CoinIcon className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow" />
                                    </div>
                                  )}
                                  {encounter.type === "Loot" && (
                                    <div className="flex items-center">
                                      {" "}
                                      {
                                        gameData.ITEMS[encounter.tier as any]
                                      }{" "}
                                      <LootIcon
                                        type={
                                          gameData.ITEM_SLOTS[
                                            gameData.ITEMS[
                                              encounter.tier as any
                                            ].replace(/\s+/g, "")
                                          ]
                                        }
                                        className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow"
                                      />
                                    </div>
                                  )}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {encounter.level}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {encounter.health}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center gap-1 items-center">
                                  {encounter.type === "Blade" && (
                                    <BladeIcon className="h-4" />
                                  )}
                                  {encounter.type === "Bludgeon" && (
                                    <BludgeonIcon className="h-4" />
                                  )}
                                  {encounter.type === "Magic" && (
                                    <MagicIcon className="h-4" />
                                  )}

                                  {encounter.encounter === "Beast" && (
                                    <>
                                      <span>/</span>
                                      {encounter.type === "Blade" && (
                                        <HideIcon className="h-4" />
                                      )}
                                      {encounter.type === "Bludgeon" && (
                                        <MetalIcon className="h-4" />
                                      )}
                                      {encounter.type === "Magic" && (
                                        <ClothIcon className="h-4" />
                                      )}
                                    </>
                                  )}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {encounter.location}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex items-center gap-1">
                                  <span className="uppercase">
                                    {encounter.dodgeRoll &&
                                    (encounter.encounter === "Beast"
                                      ? adventurer?.wisdom!
                                      : adventurer?.intelligence!) >=
                                      encounter.dodgeRoll
                                      ? "Yes"
                                      : "No"}
                                  </span>
                                  <span className="flex justify-center">
                                    {encounter.dodgeRoll &&
                                      `(${encounter.dodgeRoll})`}
                                  </span>
                                </span>
                              </td>
                              <td
                                className={`py-2 border-b border-terminal-green ${
                                  encounter.isCritical!
                                    ? "text-red-500"
                                    : encounter.isCritical!
                                    ? "text-terminal-yellow"
                                    : ""
                                }`}
                              >
                                {encounter.isCritical! && (
                                  <span className="flex justify-center">
                                    {encounter.isCritical!
                                      ? `${encounter.isCritical}%`
                                      : "No"}
                                  </span>
                                )}
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center text-terminal-yellow">
                                  {encounter.nextXp} (
                                  {calculateLevel(encounter.nextXp)})
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                {encounter.encounter === "Obstacle" &&
                                  encounter.dodgeRoll! >
                                    adventurer?.intelligence! && (
                                    <span className="flex justify-center">
                                      -{encounter.damage}hp
                                    </span>
                                  )}

                                {encounter.encounter === "Beast" &&
                                  encounter.dodgeRoll! >
                                    adventurer?.wisdom! && (
                                    <span className="flex justify-center">
                                      -{encounter.damage}hp
                                    </span>
                                  )}
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {nextAdventurerState.gold}
                                </span>
                              </td>
                              <td className="py-2 border-b border-terminal-green">
                                <span className="flex justify-center">
                                  {nextAdventurerState?.health}
                                </span>
                              </td>
                            </tr>
                          );
                        })
                      )
                    ) : (
                      <tr className="flex items-center h-10 absolute">
                        <span className="p-4">Waiting for new entropy...</span>
                      </tr>
                    )}
                  </tbody>
                </table>
              </React.Fragment>
            ))}
        </div>
      </div>
    </Draggable>
  );
};

export default EncounterTable;
