import React, { useState } from "react";
import { useTransactionCart } from "../context/TransactionCartProvider";
import {
  useTransactionManager,
  useWaitForTransaction,
} from "@starknet-react/core";
import { Button } from "./Button";

const TransactionCart = () => {
  const { handleSubmitCalls, addToCalls, calls } = useTransactionCart();
  const { addTransaction } = useTransactionManager();
  const [isOpen, setIsOpen] = useState(false);
  const [hash, setHash] = useState<string | undefined>(undefined);
  const { data, isLoading, error } = useWaitForTransaction({
    hash,
    watch: true,
  });

  const txLoading = data?.status == "RECEIVED" || data?.status == "PENDING";

  const toggleDropdown = () => {
    setIsOpen(!isOpen);
  };

  console.log(calls);

  return (
    <>
      <button
        onClick={toggleDropdown}
        className="flex p-2 bg-black border border-terminal-green relative"
      >
        {isOpen ? "Hide Cart" : "Show Cart"}
      </button>
      {isOpen ? (
        <div className="absolute right-[262px] top-20 z-10 w-[400px] h-[400px] p-3 bg-terminal-black border border-terminal-green">
          <p className="text-2xl">TRANSACTIONS</p>
          <div className="w-full border border-terminal-green "></div>
          <div className="flex flex-col h-[200px] overflow-auto">
            {calls.map((call, i) => (
              <div key={i}>
                <div className="flex flex-col gap-2">
                  {/* {call && <p>{call.selector}</p>} */}
                  {call && <p>{call.entrypoint}</p>}
                  {/* {call && <p>{call.metadata.method}</p>}
                    {call && <p>{call.metadata.description}</p>} */}
                </div>
              </div>
            ))}
          </div>
          <div className="m-2">
            <Button
              onClick={async () =>
                await handleSubmitCalls().then((tx: any) => {
                  setHash(tx.transaction_hash);
                  addTransaction({
                    hash: tx.transaction_hash,
                    metadata: {
                      method: "Performing multicall",
                      description: "Transactions have been batched and sent!",
                    },
                  });
                })
              }
              className="absolute bottom-4"
            >
              Submit all Transactions
            </Button>
          </div>
          <>
            {txLoading && hash && (
              <div className="loading-ellipsis">Loading</div>
            )}
            {hash && <div className="flex flex-col">Hash: {hash[-1]}</div>}
            {error && <div>Error: {JSON.stringify(error)}</div>}
            {data && <div>Status: {data.status}</div>}
          </>
        </div>
      ) : null}
    </>
  );
};

export default TransactionCart;
