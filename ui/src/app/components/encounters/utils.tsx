import { QueryData } from "@/app/hooks/useQueryStore";
import { AdventurerClass } from "@/app/lib/classes";
import { vitalityIncrease } from "@/app/lib/constants";
import { GameData } from "@/app/lib/data/GameData";
import { getItemData, getItemPrice } from "@/app/lib/utils";
import {
  getDecisionTree,
  getOutcomesWithPath,
} from "@/app/lib/utils/processFutures";
import {
  Item,
  ItemPurchase,
  ItemPurchaseObject,
  UpgradeStats,
} from "@/app/types";

export function getUpdatedAdventurer(
  adventurer: AdventurerClass | undefined,
  upgrades: UpgradeStats,
  potionAmount: number,
  purchaseItemsObjects: ItemPurchaseObject[]
): AdventurerClass | null {
  if (!adventurer) return null;

  let updatedAdventurer: AdventurerClass = { ...adventurer };

  if (upgrades.Strength > 0) {
    updatedAdventurer.strength! += upgrades.Strength;
  }
  if (upgrades.Dexterity > 0) {
    updatedAdventurer.dexterity! += upgrades.Dexterity;
  }
  if (upgrades.Vitality > 0) {
    updatedAdventurer.vitality =
      Number(updatedAdventurer.vitality) + upgrades.Vitality;
    updatedAdventurer.health =
      updatedAdventurer.health! + upgrades.Vitality! * vitalityIncrease;
  }
  if (upgrades.Intelligence > 0) {
    updatedAdventurer.intelligence! += upgrades.Intelligence;
  }
  if (upgrades.Wisdom > 0) {
    updatedAdventurer.wisdom! += upgrades.Wisdom;
  }
  if (upgrades.Charisma > 0) {
    updatedAdventurer.charisma! += upgrades.Charisma;
  }

  // Apply purchased potions
  if (potionAmount > 0) {
    updatedAdventurer.health = Math.min(
      updatedAdventurer.health! + potionAmount * 10,
      100 + updatedAdventurer.vitality! * vitalityIncrease
    );
  }

  const totalCost = purchaseItemsObjects.reduce((acc, item) => {
    return acc + getItemPrice(item.tier, updatedAdventurer?.charisma!);
  }, 0);

  updatedAdventurer.gold = adventurer?.gold! - totalCost;

  return updatedAdventurer;
}

export function getPurchaseItemsObjects(
  purchaseItems: ItemPurchase[],
  gameData: GameData
): ItemPurchaseObject[] {
  const purchaseItemsObjects = purchaseItems
    .filter((item) => item.equip === "1")
    .map((item) => {
      const itemName = gameData.ITEMS[Number(item.item)];
      return getItemData(itemName);
    });

  return purchaseItemsObjects;
}

export function getItems(
  purchaseItems: ItemPurchase[],
  data: QueryData,
  gameData: GameData
): Item[] {
  const purchaseItemsObjects = getPurchaseItemsObjects(purchaseItems, gameData);

  // const items = useMemo(() => {
  let equippedItems: Item[] =
    data.itemsByAdventurerQuery?.items
      .filter((item) => item.equipped)
      .map((item) => ({
        item: item.item,
        ...getItemData(item.item ?? ""),
        special2: item.special2,
        special3: item.special3,
        xp: Math.max(1, item.xp!),
      })) || [];

  let updatedItems: Item[] = equippedItems.map((item: any) => {
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
  // }, [data.itemsByAdventurerQuery?.items, purchaseItemsObjects]);
  // return items;
}

export function getPaths(
  updatedAdventurer: AdventurerClass | null,
  adventurerEntropy: bigint,
  items: Item[],
  gameData: GameData,
  data: QueryData,
  hasBeast: boolean
) {
  // const purchaseItems = useUIStore((state) => state.purchaseItems);
  // const hasBeast = useAdventurerStore((state) => state.computed.hasBeast);
  // const items = getItems(purchaseItems, data, gameData);

  // const outcomesWithPath = useMemo(() => {
  if (!updatedAdventurer || !items) return [];
  const decisionTree = getDecisionTree(
    updatedAdventurer!,
    items,
    adventurerEntropy,
    hasBeast,
    updatedAdventurer?.level!
  );
  return getOutcomesWithPath(decisionTree).sort(
    (a, b) =>
      b[b.length - 1].adventurer.health! - a[a.length - 1].adventurer.health!
  );
  // }, [updatedAdventurer?.xp, adventurerEntropy, items]);

  // return outcomesWithPath;
}
