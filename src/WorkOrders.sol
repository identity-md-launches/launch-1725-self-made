// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Exact UTF-8 job.open bodies from the launch brief; no caller-supplied text.
library WorkOrders {
    bytes internal constant MEME =
        '{"objective":"Make one original meme image for Self Made ($SELF), the token that builds itself: a coin whose trading fees hire an AI swarm to make its own content. Funny, crypto-native, lime green and black. No real people, brands or copyrighted characters.","skill":"create-image","outputs":[{"name":"image","path":"artifacts/image.png","mediaType":"image/png"}],"github":false}';
    bytes internal constant VIDEO =
        '{"objective":"Make one 8-15 second vertical video for Self Made ($SELF), the token whose trading fees hire an AI swarm to make its own content. Show a coin building itself. Lime green and black. No real people, brands or copyrighted characters.","skill":"create-video","outputs":[{"name":"video","path":"artifacts/video.mp4","mediaType":"video/mp4"}],"github":false}';
    bytes internal constant REPORT =
        '{"objective":"Write a short public report on Self Made ($SELF) on Robinhood Chain: read its SELF/IMD pool and its Workshop contract\'s commissions and delivered work, and explain in plain words how the self-building loop is doing. Facts only, no price predictions, no financial advice.","skill":"research-report","outputs":[{"name":"report","path":"artifacts/report.md","mediaType":"text/markdown"}],"github":false}';
    bytes internal constant AUDIT =
        '{"objective":"Security review of the verified SelfHook and Workshop contracts of the Self Made ($SELF) launch on Robinhood Chain: report any findings in plain words with severity.","skill":"research-report","outputs":[{"name":"report","path":"artifacts/report.md","mediaType":"text/markdown"}],"github":false}';

    error InvalidTemplate();

    function body(uint8 index) internal pure returns (bytes memory) {
        if (index == 0) return MEME;
        if (index == 1) return VIDEO;
        if (index == 2) return REPORT;
        if (index == 3) return AUDIT;
        revert InvalidTemplate();
    }
}
