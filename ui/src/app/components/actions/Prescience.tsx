import React from "react";
import EncounterTable from "../encounters/EncounterTable";

const Prescience = () => {
  return (
    <div className="flex flex-col gap-2 h-full">
      <h3 className="text-center uppercase">Prescience</h3>
      <div className="flex flex-col gap-5 sm:gap-0 sm:flex-row justify-between w-full text-xs sm:text-base overflow-auto">
        <div className="flex flex-col w-full flex-grow-2 p-2">
          <EncounterTable />
        </div>
      </div>
    </div>
  );
};

export default Prescience;
