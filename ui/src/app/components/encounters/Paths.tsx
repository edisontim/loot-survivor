import {
  BladeIcon,
  BludgeonIcon,
  ClothIcon,
  CoinIcon,
  DownArrowIcon,
  HeartVitalityIcon,
  HideIcon,
  InfoIcon,
  MagicIcon,
  MetalIcon,
} from "@/app/components/icons/Icons";
import LootIcon from "@/app/components/icons/LootIcon";
import { AdventurerClass } from "@/app/lib/classes";
import { GameData } from "@/app/lib/data/GameData";
import { calculateLevel } from "@/app/lib/utils";
import { Step } from "@/app/lib/utils/processFutures";
import { Item } from "@/app/types";
import React, { useState } from "react";

type PathProps = {
  adventurerEntropy: bigint;
  updatedAdventurer: AdventurerClass | null;
  outcomesWithPath: Step[][];
  armoritems: Item[];
  weaponItems: Item[];
  startingLevel: number | undefined;
};

const Paths = ({
  adventurerEntropy,
  updatedAdventurer,
  outcomesWithPath,
  armoritems,
  weaponItems,
  startingLevel,
}: PathProps) => {
  const [hoveredBeast, setHoveredBeast] = useState<number | null>(null);

  let gameData = new GameData();

  return (
    <>
      {updatedAdventurer?.entropy &&
        outcomesWithPath.map((steps: Step[], index: number) => (
          <div key={index} className="mt-2">
            <div>
              Path {steps.map((step) => step.previousDecision).join(" -> ")}
            </div>
            <table className="border-separate border-spacing-0 w-full sm:text-sm xl:text-sm 2xl:text-sm block overflow-x-scroll sm:overflow-y-scroll default-scroll p-2">
              <thead
                className="border border-terminal-green sticky top-0 bg-terminal-black uppercase"
                style={{ zIndex: 8 }}
              >
                <tr className="border border-terminal-green">
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    XP
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Type
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Encounter
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
                  <th className="relative py-2 px-1 border-b border-terminal-green">
                    Avoid
                  </th>
                  <th className="relative py-2 px-1 border-b border-terminal-green">
                    Tip
                  </th>
                  <th className="py-2 px-1 sm:pr-3 border-b border-terminal-green">
                    Crit
                  </th>
                  <th className="py-2 px-1 border-b border-terminal-green">
                    Next (Lvl)
                  </th>
                  <th className="py-2 px-1 border-b border-terminal-green">
                    Ambush
                  </th>
                  <th className="py-2 px-1 border-b border-terminal-green">
                    Gold after
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
                        return (
                          <tr>
                            <td>Death</td>
                          </tr>
                        );
                      }
                      const nextAdventurerState =
                        steps[index + 1]?.adventurer || adventurer;
                      if (!encounter) {
                        let levelUps =
                          calculateLevel(adventurer.xp || 4) -
                          (startingLevel || 1);

                        return (
                          <tr>
                            <td aria-colspan={12}>
                              <span className="flex flex-row gap-1 justify-center">
                                {"Level Up!"}
                                <span className="text-terminal-yellow flex">
                                  {Array.from({ length: levelUps }).map(
                                    (_, index) => (
                                      <DownArrowIcon
                                        key={index}
                                        className="h-4 transform rotate-180"
                                      />
                                    )
                                  )}
                                </span>
                              </span>
                            </td>
                          </tr>
                        );
                      }
                      let [special2, special3] = encounter.specialName?.split(
                        " "
                      ) || ["no", "no"];
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
                            <span className="flex">{encounter.xp}</span>
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
                              (encounter?.level || 1) >= 19 && (
                                <span className="tooltiptext bottom">
                                  {encounter.specialName}
                                </span>
                              )}
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.encounter !== "Discovery" && (
                                <div className="relative flex flex-row gap-1 items-center justify-center w-full">
                                  <span className="text-xs">PWR</span>
                                  <span>{encounter.power}</span>
                                  <span className="absolute bottom-[-10px] text-terminal-yellow text-xs">
                                    T{encounter.tier} L{encounter.level}
                                  </span>
                                </div>
                              )}
                              {encounter.type === "Health" && (
                                <div className="flex items-center">
                                  {" "}
                                  <HeartVitalityIcon className="h-3 pl-0.5" />
                                  {encounter.tier}{" "}
                                </div>
                              )}
                              {encounter.type === "Gold" && (
                                <div className="flex items-center">
                                  {" "}
                                  <CoinIcon className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow" />
                                  {encounter.tier}{" "}
                                </div>
                              )}
                              {encounter.type === "Loot" && (
                                <div className="flex items-center">
                                  {" "}
                                  {
                                    gameData.ITEMS[encounter.tier as number]
                                  }{" "}
                                  <LootIcon
                                    type={
                                      gameData.ITEM_SLOTS[
                                        gameData.ITEMS[
                                          encounter.tier as number
                                        ].replace(/\s+/g, "")
                                      ]
                                    }
                                    size={"w-4"}
                                    className="pl-0.5 mt-0.5 self-center h-4 fill-current text-terminal-yellow"
                                  />
                                </div>
                              )}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center">
                              {encounter.health}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="relative flex justify-center gap-1 items-center uppercase">
                              {encounter.encounter === "Beast" && (
                                <span
                                  className="absolute top-[-8px] right-[-5px] w-3 h-3 cursor-pointer"
                                  onMouseEnter={() => setHoveredBeast(index)}
                                  onMouseLeave={() => setHoveredBeast(null)}
                                >
                                  <InfoIcon />
                                  {hoveredBeast === index && (
                                    <span className="absolute flex flex-row items-center gap-1 p-2 border border-terminal-green bg-terminal-black">
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
                                  )}
                                </span>
                              )}
                              {encounter.encounter === "Beast" ? (
                                (encounter.type === "Blade" && "Hunter") ||
                                (encounter.type === "Bludgeon" && "Brute") ||
                                (encounter.type === "Magic" && "Magical")
                              ) : (
                                <>
                                  {encounter.type === "Blade" && (
                                    <BladeIcon className="h-4" />
                                  )}
                                  {encounter.type === "Bludgeon" && (
                                    <BludgeonIcon className="h-4" />
                                  )}
                                  {encounter.type === "Magic" && (
                                    <MagicIcon className="h-4" />
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
                            <span className="flex justify-center uppercase">
                              {encounter.dodgeRoll &&
                              (encounter.encounter === "Beast"
                                ? adventurer?.wisdom!
                                : adventurer?.intelligence!) >=
                                encounter.dodgeRoll
                                ? "Yes"
                                : "No"}
                            </span>
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex gap-1 justify-center uppercase text-terminal-yellow">
                              {encounter.dodgeRoll && (
                                <>
                                  <span>
                                    {encounter.encounter === "Beast"
                                      ? "WIS"
                                      : "INT"}
                                  </span>
                                  <span>{encounter.dodgeRoll}</span>
                                </>
                              )}
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
                              {nextAdventurerState.xp} (
                              {calculateLevel(Number(nextAdventurerState.xp))})
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
                              encounter.dodgeRoll! > adventurer?.wisdom! && (
                                <span className="flex justify-center">
                                  -{encounter.damage}hp
                                </span>
                              )}
                          </td>
                          <td className="py-2 border-b border-terminal-green">
                            <span className="flex justify-center uppercase">
                              {
                                <span className="flex flex-row items-center text-terminal-yellow">
                                  <CoinIcon className="h-4 fill-current text-terminal-yellow" />
                                  {nextAdventurerState.gold}
                                </span>
                              }
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
                    <td aria-colspan={12}>
                      <span className="p-4">Waiting for new entropy...</span>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        ))}
    </>
  );
};

export default Paths;
