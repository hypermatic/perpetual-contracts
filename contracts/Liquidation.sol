// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./lib/LibMath.sol";
import "./lib/LibLiquidation.sol";
import "./lib/LibBalances.sol";
import "./lib/LibPerpetuals.sol";
import "./Interfaces/ILiquidation.sol";
import "./Interfaces/ITrader.sol";
import "./Interfaces/ITracerPerpetualSwaps.sol";
import "./Interfaces/ITracerPerpetualsFactory.sol";
import "./Interfaces/IOracle.sol";
import "./Interfaces/IPricing.sol";
import "./Interfaces/IInsurance.sol";

import "hardhat/console.sol";

/**
 * Each call enforces that the contract calling the account is only updating the balance
 * of the account for that contract.
 */
contract Liquidation is ILiquidation, Ownable {
    using LibMath for uint256;
    using LibMath for int256;

    uint256 public override currentLiquidationId;
    uint256 public override maxSlippage;
    uint256 releaseTime = 15 minutes;
    IPricing public pricing;
    ITracerPerpetualSwaps public tracer;
    address public insuranceContract;

    // Receipt ID => LiquidationReceipt
    mapping(uint256 => LibLiquidation.LiquidationReceipt)
        public liquidationReceipts;
    // Factor to keep precision in percent calculations
    int256 private constant PERCENT_PRECISION = 10000;

    event ClaimedReceipts(
        address indexed liquidator,
        address indexed market,
        uint256 indexed receiptId
    );
    event ClaimedEscrow(
        address indexed liquidatee,
        address indexed market,
        uint256 indexed id
    );
    event Liquidate(
        address indexed account,
        address indexed liquidator,
        int256 liquidationAmount,
        Perpetuals.Side side,
        address indexed market,
        uint256 liquidationId
    );
    event InvalidClaimOrder(uint256 indexed receiptId);

    constructor(
        address _pricing,
        address _tracer,
        address _insuranceContract,
        uint256 _maxSlippage
    ) Ownable() {
        pricing = IPricing(_pricing);
        tracer = ITracerPerpetualSwaps(_tracer);
        insuranceContract = _insuranceContract;
        maxSlippage = _maxSlippage;
    }

    /**
     * @notice Creates a liquidation receipt for a given trader
     * @param liquidator the account executing the liquidation
     * @param liquidatee the account being liquidated
     * @param price the price at which this liquidation event occurred
     * @param escrowedAmount the amount of funds required to be locked into escrow
     *                       by the liquidator
     * @param amountLiquidated the amount of positions that were liquidated
     * @param liquidationSide the side of the positions being liquidated. true for long
     *                        false for short.
     */
    function submitLiquidation(
        address liquidator,
        address liquidatee,
        uint256 price,
        uint256 escrowedAmount,
        int256 amountLiquidated,
        Perpetuals.Side liquidationSide
    ) internal {
        liquidationReceipts[currentLiquidationId] = LibLiquidation
            .LiquidationReceipt({
            tracer: address(tracer),
            liquidator: liquidator,
            liquidatee: liquidatee,
            price: price,
            time: block.timestamp,
            escrowedAmount: escrowedAmount,
            releaseTime: block.timestamp + releaseTime,
            amountLiquidated: amountLiquidated,
            escrowClaimed: false,
            liquidationSide: liquidationSide,
            liquidatorRefundClaimed: false
        });
        currentLiquidationId += 1;
    }

    /**
     * @notice Allows a trader to claim escrowed funds after the escrow period has expired
     * @param receiptId The ID number of the insurance receipt from which funds are being claimed from
     */
    function claimEscrow(uint256 receiptId) public override onlyTracer {
        LibLiquidation.LiquidationReceipt memory receipt =
            liquidationReceipts[receiptId];
        require(receipt.liquidatee == msg.sender, "LIQ: Liquidatee mismatch");
        require(!receipt.escrowClaimed, "LIQ: Escrow claimed");
        require(block.timestamp > receipt.releaseTime, "LIQ: Not released");

        // Mark as claimed
        liquidationReceipts[receiptId].escrowClaimed = true;

        // Update balance
        int256 amountToReturn = receipt.escrowedAmount.toInt256();
        emit ClaimedEscrow(receipt.liquidatee, receipt.tracer, receiptId);
        tracer.updateAccountsOnClaim(
            address(0),
            0,
            receipt.liquidatee,
            amountToReturn,
            0
        );
    }

    /**
     * @notice Returns liquidation receipt data for a given receipt id.
     * @param id the receipt id to get data for
     */
    function getLiquidationReceipt(uint256 id)
        external
        view
        override
        returns (LibLiquidation.LiquidationReceipt memory)
    {
        return liquidationReceipts[id];
    }

    function verifyAndSubmitLiquidation(
        int256 base,
        uint256 price,
        int256 quote,
        int256 amount,
        uint256 gasPrice,
        address account
    ) internal returns (uint256) {
        require(amount > 0, "LIQ: Liquidation amount <= 0");
        // Limits the gas use when liquidating
        require(
            tx.gasprice <= IOracle(tracer.gasPriceOracle()).latestAnswer(),
            "LIQ: GasPrice > FGasPrice"
        );

        Balances.Position memory pos = Balances.Position(quote, base);
        uint256 gasCost = gasPrice * tracer.LIQUIDATION_GAS_COST();

        int256 currentMargin = Balances.margin(pos, price);
        // todo CASTING CHECK
        require(
            currentMargin <= 0 ||
                uint256(currentMargin) <
                Balances.minimumMargin(
                    pos,
                    price,
                    gasCost,
                    tracer.maxLeverage()
                ),
            "LIQ: Account above margin"
        );
        require(amount <= base.abs(), "LIQ: Liquidate Amount > Position");

        // calc funds to liquidate and move to Escrow
        uint256 amountToEscrow =
            LibLiquidation.calcEscrowLiquidationAmount(
                Balances.minimumMargin(
                    pos,
                    price,
                    gasCost,
                    tracer.maxLeverage()
                ),
                currentMargin
            );

        // create a liquidation receipt
        Perpetuals.Side side =
            base < 0 ? Perpetuals.Side.Short : Perpetuals.Side.Long;
        submitLiquidation(
            msg.sender,
            account,
            price,
            amountToEscrow,
            amount,
            side
        );
        return amountToEscrow;
    }

    /**
     * @notice Liquidates the margin account of a particular user. A deposit is needed from the liquidator.
     *         Generates a liquidation receipt for the liquidator to use should they need a refund.
     * @param amount The amount of tokens to be liquidated
     * @param account The account that is to be liquidated.
     */
    function liquidate(int256 amount, address account) external override {
        /* Liquidated account's balance */
        Balances.Account memory liquidatedBalance = tracer.getBalance(account);

        uint256 amountToEscrow =
            verifyAndSubmitLiquidation(
                liquidatedBalance.position.base,
                pricing.fairPrice(),
                liquidatedBalance.position.quote,
                amount,
                liquidatedBalance.lastUpdatedGasPrice,
                account
            );

        (
            int256 liquidatorQuoteChange,
            int256 liquidatorBaseChange,
            int256 liquidateeQuoteChange,
            int256 liquidateeBaseChange
        ) =
            LibLiquidation.liquidationBalanceChanges(
                liquidatedBalance.position.quote,
                liquidatedBalance.position.base,
                amount
            );

        tracer.updateAccountsOnLiquidation(
            msg.sender,
            account,
            liquidatorQuoteChange,
            liquidatorBaseChange,
            liquidateeQuoteChange,
            liquidateeBaseChange,
            amountToEscrow
        );

        emit Liquidate(
            account,
            msg.sender,
            amount,
            (
                liquidatedBalance.position.base < 0
                    ? Perpetuals.Side.Short
                    : Perpetuals.Side.Long
            ),
            address(tracer),
            currentLiquidationId - 1
        );
    }

    /**
     * @notice Calculates the number of units sold and the average price of those units by a trader
     *         given multiple order
     * @param orders a list of orders for which the units sold is being calculated from
     * @param traderContract The trader contract with which the orders were made
     * @param receiptId the id of the liquidation receipt the orders are being claimed against
     */
    function calcUnitsSold(
        Perpetuals.Order[] memory orders,
        address traderContract,
        uint256 receiptId
    ) public override returns (uint256, uint256) {
        LibLiquidation.LiquidationReceipt memory receipt =
            liquidationReceipts[receiptId];
        uint256 unitsSold;
        uint256 avgPrice;
        console.log("========");
        console.log("1");
        console.log(traderContract);
        for (uint256 i; i < orders.length; i++) {
            console.log("1.5");
            console.log(ITrader(traderContract).chainId());
            console.log("1.75");
            Perpetuals.Order memory order =
                ITrader(traderContract).getOrder(orders[i]);
            console.log("2");

            if (
                order.created < receipt.time || // Order made before receipt
                order.maker != receipt.liquidator || // Order made by someone who isn't liquidator
                order.side == receipt.liquidationSide // Order is in same direction as liquidation
                /* Order should be the opposite to the position acquired on liquidation */
            ) {
                emit InvalidClaimOrder(receiptId);
                console.log("3");
                continue;
            }

            console.log("4");

            if (
                (receipt.liquidationSide == Perpetuals.Side.Long &&
                    order.price >= receipt.price) ||
                (receipt.liquidationSide == Perpetuals.Side.Short &&
                    order.price <= receipt.price)
            ) {
                // Liquidation position was long
                // Price went up, so not a slippage order
                // or
                // Liquidation position was short
                // Price went down, so not a slippage order
                emit InvalidClaimOrder(receiptId);
                console.log("5");
                continue;
            }
            console.log("6");
            uint256 orderFilled = ITrader(traderContract).filledAmount(order);
            console.log("7");

            /* order.created >= receipt.time
             * && order.maker == receipt.liquidator
             * && order.side != receipt.liquidationSide */
            unitsSold = unitsSold + orderFilled;
            console.log("8");
            avgPrice = avgPrice + (order.price * orderFilled);
            console.log("9");
        }

        console.log("10");
        // Avoid divide by 0 if no orders sold
        if (unitsSold == 0) {
            return (0, 0);
        }
        console.log("11");
        return (unitsSold, avgPrice / unitsSold);
    }

    /**
     * @notice Marks receipts as claimed and returns the refund amount
     * @param escrowId the id of the receipt created during the liquidation event
     * @param orders the orders that sell the liquidated positions
     * @param traderContract the address of the trader contract the selling orders were made by
     */
    function calcAmountToReturn(
        uint256 escrowId,
        Perpetuals.Order[] memory orders,
        address traderContract
    ) public override returns (uint256) {
        LibLiquidation.LiquidationReceipt memory receipt =
            liquidationReceipts[escrowId];
        // Validate the escrowed order was fully sold
        (uint256 unitsSold, uint256 avgPrice) =
            calcUnitsSold(orders, traderContract, escrowId);
        require(
            unitsSold <= uint256(receipt.amountLiquidated.abs()),
            "LIQ: Unit mismatch"
        );

        uint256 amountToReturn =
            LibLiquidation.calculateSlippage(
                unitsSold,
                maxSlippage,
                avgPrice,
                receipt
            );
        return amountToReturn;
    }

    /**
     * @notice Drains a certain amount from insurance pool to cover excess slippage not covered by escrow
     * @param amountWantedFromInsurance How much we want to drain
     * @param receipt The liquidation receipt for which we are calling on the insurance pool to cover
     */
    function drainInsurancePoolOnLiquidation(
        uint256 amountWantedFromInsurance,
        LibLiquidation.LiquidationReceipt memory receipt
    )
        internal
        returns (
            uint256 _amountTakenFromInsurance,
            uint256 _amountToGiveToClaimant
        )
    {
        /*
         * If there was not enough escrowed, we want to call the insurance pool to help out.
         * First, check the margin of the insurance Account. If this is enough, just drain from there.
         * If this is not enough, call Insurance.drainPool to get some tokens from the insurance pool.
         * If drainPool is able to drain enough, drain from the new margin.
         * If the margin still does not have enough after calling drainPool, we are not able to fully
         * claim the receipt, only up to the amount the insurance pool allows for.
         */

        Balances.Account memory insuranceBalance =
            tracer.getBalance(insuranceContract);
        if (
            insuranceBalance.position.quote >=
            amountWantedFromInsurance.toInt256()
        ) {
            // We don't need to drain insurance contract. The balance is already in the market contract
            _amountTakenFromInsurance = amountWantedFromInsurance;
        } else {
            // insuranceBalance.quote < amountWantedFromInsurance
            if (insuranceBalance.position.quote <= 0) {
                // attempt to drain entire balance that is needed from the pool
                IInsurance(insuranceContract).drainPool(
                    amountWantedFromInsurance
                );
            } else {
                // attempt to drain the required balance taking into account the insurance balance in the account contract
                IInsurance(insuranceContract).drainPool(
                    amountWantedFromInsurance -
                        uint256(insuranceBalance.position.quote)
                );
            }
            Balances.Account memory updatedInsuranceBalance =
                tracer.getBalance(insuranceContract);
            if (
                updatedInsuranceBalance.position.quote <
                amountWantedFromInsurance.toInt256()
            ) {
                // Still not enough
                _amountTakenFromInsurance = uint256(
                    updatedInsuranceBalance.position.quote
                );
            } else {
                _amountTakenFromInsurance = amountWantedFromInsurance;
            }
        }

        _amountToGiveToClaimant =
            receipt.escrowedAmount +
            _amountTakenFromInsurance;
        // Don't add any to liquidatee
    }

    /**
     * @notice Allows a liquidator to submit a single liquidation receipt and multiple order ids. If the
     *         liquidator experienced slippage, will refund them a proportional amount of their deposit.
     * @param receiptId Used to identify the receipt that will be claimed
     * @param orders The orders that sold the liquidated position
     */
    function claimReceipt(
        uint256 receiptId,
        Perpetuals.Order[] memory orders,
        address traderContract
    ) external override {
        // Claim the receipts from the escrow system, get back amount to return
        LibLiquidation.LiquidationReceipt memory receipt =
            liquidationReceipts[receiptId];

        // Mark refund as claimed
        require(!receipt.liquidatorRefundClaimed, "LIQ: Already claimed");
        liquidationReceipts[receiptId].liquidatorRefundClaimed = true;

        require(receipt.liquidator == msg.sender, "LIQ: Liquidator mismatch");
        require(
            block.timestamp < receipt.releaseTime,
            "LIQ: claim time passed"
        );
        require(
            tracer.tradingWhitelist(traderContract),
            "LIQ: Trader is not whitelisted"
        );

        uint256 amountToReturn =
            calcAmountToReturn(receiptId, orders, traderContract);

        if (amountToReturn > receipt.escrowedAmount) {
            liquidationReceipts[receiptId].escrowedAmount = 0;
        } else {
            liquidationReceipts[receiptId].escrowedAmount =
                receipt.escrowedAmount -
                amountToReturn;
        }

        // Keep track of how much was actually taken out of insurance
        uint256 amountTakenFromInsurance;
        uint256 amountToGiveToClaimant;
        uint256 amountToGiveToLiquidatee;

        if (amountToReturn > receipt.escrowedAmount) {
            // Need to cover some loses with the insurance contract
            // Whatever is the remainder that can't be covered from escrow
            uint256 amountWantedFromInsurance =
                amountToReturn - receipt.escrowedAmount;
            (
                amountTakenFromInsurance,
                amountToGiveToClaimant
            ) = drainInsurancePoolOnLiquidation(
                amountWantedFromInsurance,
                receipt
            );
        } else {
            amountToGiveToClaimant = amountToReturn;
            amountToGiveToLiquidatee = receipt.escrowedAmount - amountToReturn;
        }
        tracer.updateAccountsOnClaim(
            receipt.liquidator,
            amountToGiveToClaimant.toInt256(),
            receipt.liquidatee,
            amountToGiveToLiquidatee.toInt256(),
            amountTakenFromInsurance.toInt256()
        );
        emit ClaimedReceipts(msg.sender, address(tracer), receiptId);
    }

    function transferOwnership(address newOwner)
        public
        override(Ownable, ILiquidation)
        onlyOwner
    {
        super.transferOwnership(newOwner);
    }

    /**
     * @notice Modifies the release time
     * @param _releaseTime new release time
     */
    function setReleaseTime(uint256 _releaseTime) external onlyOwner() {
        releaseTime = _releaseTime;
    }

    function setMaxSlippage(uint256 _maxSlippage) public override onlyOwner() {
        maxSlippage = _maxSlippage;
    }

    modifier onlyTracer() {
        require(msg.sender == address(tracer), "LIQ: Caller not Tracer market");
        _;
    }
}
