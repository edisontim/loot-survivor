import React from "react";
import useUIStore from "@/app/hooks/useUIStore";
import { MdClose } from "react-icons/md";
import EncounterTable from "./EncounterTable";

const EncounterDialog = () => {
  const showEncounterTable = useUIStore((state) => state.showEncounterTable);

  return (
    <div className="flex flex-col gap-5 sm:gap-0 sm:flex-row justify-between w-full bg-terminal-black max-h-[300px] border border-terminal-green text-xs sm:text-base">
      <div className="flex flex-col w-full flex-grow-2 p-2">
        <div className="flex w-full justify-center h-8"></div>
        <button
          className="absolute top-0 right-0 z-10"
          onClick={() => showEncounterTable(false)}
        >
          <MdClose className="w-10 h-10" />
        </button>

        <EncounterTable />
      </div>
    </div>
  );
};

export default EncounterDialog;
