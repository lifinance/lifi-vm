// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

enum Scope {
    Multichain,
    ChainSpecific
}

enum ResetPeriod {
    OneSecond,
    FifteenSeconds,
    OneMinute,
    TenMinutes,
    OneHourAndFiveMinutes,
    OneDay,
    SevenDaysAndOneHour,
    ThirtyDays
}
