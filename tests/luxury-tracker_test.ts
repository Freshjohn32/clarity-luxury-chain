import {
    Clarinet,
    Tx,
    Chain,
    Account,
    types
} from 'https://deno.land/x/clarinet@v1.0.0/index.ts';
import { assertEquals } from 'https://deno.land/std@0.90.0/testing/asserts.ts';

Clarinet.test({
    name: "Ensure that item registration works",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const deployer = accounts.get('deployer')!;
        
        let block = chain.mineBlock([
            Tx.contractCall('luxury-tracker', 'register-item', 
                [types.utf8("Luxury Watch XYZ123")], 
                deployer.address
            )
        ]);
        
        block.receipts[0].result.expectOk().expectUint(1);
        
        let getItem = chain.callReadOnlyFn(
            'luxury-tracker',
            'get-item-details',
            [types.uint(1)],
            deployer.address
        );
        
        getItem.result.expectSome();
    },
});

Clarinet.test({
    name: "Test ownership transfer",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const deployer = accounts.get('deployer')!;
        const wallet1 = accounts.get('wallet_1')!;
        
        // First register an item
        let block = chain.mineBlock([
            Tx.contractCall('luxury-tracker', 'register-item',
                [types.utf8("Luxury Watch XYZ123")],
                deployer.address
            )
        ]);
        
        // Then transfer it
        let transfer = chain.mineBlock([
            Tx.contractCall('luxury-tracker', 'transfer-ownership',
                [types.uint(1), types.principal(wallet1.address)],
                deployer.address
            )
        ]);
        
        transfer.receipts[0].result.expectOk().expectBool(true);
        
        // Verify new owner
        let getItem = chain.callReadOnlyFn(
            'luxury-tracker',
            'get-item-details',
            [types.uint(1)],
            deployer.address
        );
        
        getItem.result.expectSome();
    },
});
