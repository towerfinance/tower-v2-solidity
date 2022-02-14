//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IFirebirdZap {

  // _to: must be a pair lp
  // _from: must be in lp
  // _amounts: amount_from, _minTokenB, _minLp
  function zapInToken(
    address _from,
    uint256[] calldata amounts,
    address _to,
    uint8 dexId,
    address uniRouter,
    bool transferResidual
  ) external returns (uint256 lpAmt);

  // _from: must be a pair lp
  // _toToken: must be in lp
  function zapOut(
    address _from,
    uint256 amount,
    address _toToken,
    uint256 _minTokensRec,
    uint8 dexId,
    address uniRouter
  ) external returns (uint256 tokenBought);
}