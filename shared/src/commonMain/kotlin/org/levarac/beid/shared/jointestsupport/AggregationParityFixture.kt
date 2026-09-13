package org.levarac.beid.shared.jointestsupport

/** One checked native-adapter parity fixture; native tests parse and feed their production adapters. */
public fun aggregationParityFixtureJson(): String = """
        [{"windowIndex":0,"peerKey":"rpid-a","displayId":"0xAABBCCDD"},{"windowIndex":0,"peerKey":"rpid-a","displayId":"0xaabbccdd"},{"windowIndex":1,"peerKey":"rpid-b","displayId":"0xAABBCCDD"},{"windowIndex":2,"peerKey":"rpid-c","displayId":null},{"windowIndex":2,"peerKey":"rpid-d","displayId":"0x01020304"}]
    """
public fun aggregationParityExpectedObservations(): Int = 5
public fun aggregationParityExpectedWindows(): Int = 3
public fun aggregationParityExpectedDevices(): Int = 2
public fun aggregationParityExpectedMutualObservations(): Int = 0
