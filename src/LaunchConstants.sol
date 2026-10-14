// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library LaunchConstants {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    bytes32 internal constant ACTION = bytes32("job.open@job-1");
    uint24 internal constant LP_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
}
