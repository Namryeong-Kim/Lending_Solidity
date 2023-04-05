// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import "./DreamOracle.sol";
import "forge-std/console.sol";
import "./ABDKMath64x64.sol";


interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function setPrice(address token, uint256 price) external;
}

/**
ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
- 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
- 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
- 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
- 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
 */

 /**
 1block -> 12sec
 24hours -> 7200blocks -> 86400sec
  */

contract DreamAcademyLending{
    struct VaultInfo{
        uint256 collateralETH;
        uint256 depositUSDC;
        uint256 availableBorrowETH2USDC;
        uint256 borrowUSDC;
        uint256 borrowBlockNumber;
    }
    uint256 constant LTV = 50;
    uint256 constant LT = 75;
    uint256 constant ONE_DAY_BLOCKS_TIME = 86400;
    uint256 constant ONE_DAY_BLOCKS = 7200;

    uint256 totalBorrowUSDC;
    uint256 totalDepositUSDC;
    

    address token;
    IPriceOracle oracle;
    mapping(address => VaultInfo) vaults;

    constructor(IPriceOracle _oracle, address _token) {
        token = _token;
        oracle = _oracle;
        vaults[msg.sender].borrowBlockNumber;
    }

    function initializeLendingProtocol(address _tokenAddress) external payable{
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), msg.value);
        totalDepositUSDC += msg.value;
    }

    /** deposi(입금)
    ETH <-> USDC (2 cases)
    1. _amount만큼 담보로 저장 (ETH: msg.value, USDC: _amount)
    2. 해당 amount로 얼마 빌릴 수 있는지 구하기
    3. VaultInfo update
    */
    function deposit(address _tokenAddress, uint256 _amount) external payable{
        require(_tokenAddress == address(0x0) || _tokenAddress == token, "We do not support!");
        VaultInfo memory tempVault = vaults[msg.sender]; 
        
        if(_tokenAddress == address(0x0)){ //담보로 맡길 ETH
            require(msg.value != 0, "error");
            require(msg.value == _amount, "false");
            tempVault.collateralETH += msg.value;
   
        }
        else{ //borrower에게 빌려줄 USDC 예금
        //msg.sender의 balanceOf >= _amount
            require(_amount!= 0, "INSUFFICIENT_AMOUNT");
            require(IERC20(_tokenAddress).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_DEPOSIT_AMOUNT");
            IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount);
            tempVault.depositUSDC += _amount;
            totalDepositUSDC += _amount;
        }
        vaults[msg.sender] = tempVault;
    }


    /** borrow
    1$ pegging -> 1USDC = 1$
    1. msg.sender가 빌릴 수 있는양 계산(잔고x담보ETHxLTV) -> 빌릴 수 있는 양은 빌리려고 하는 양보다 많아야 함
    담보 있을 때 예금도 빌리려는 만큼 있어야 하고, 빌리려는 만큼 담보도 있어야함
    */
    function borrow(address _tokenAddress, uint256 _amount) external{
        _update();
        VaultInfo memory tempVault = vaults[msg.sender]; 
        
        require(tempVault.availableBorrowETH2USDC >= _amount+tempVault.borrowUSDC, "INSUFFICIENT_COLLATERAL_AMOUNT");
        //require(healthFactorCheck > 1, "NOT_HEALTY");

        tempVault.borrowUSDC += _amount;
        totalBorrowUSDC += _amount;
        tempVault.borrowBlockNumber = block.number;
        IERC20(token).transfer(msg.sender, _amount);
        
        vaults[msg.sender] = tempVault;
        _update();
        
    }

    function repay(address _tokenAddress, uint256 _amount) external{
        _update();
        VaultInfo memory tempVault = vaults[msg.sender];
        require(tempVault.borrowUSDC >= _amount, "INSUFFICIENT_REPAY_AMOUNT");
        //require(healthFactorCheck > 1, "NOT_HEALTY");

        IERC20(token).transferFrom(msg.sender, address(this), _amount);
        tempVault.borrowUSDC -= _amount;
        totalBorrowUSDC -= _amount;
        vaults[msg.sender] = tempVault;
    }

    function liquidate(address _user, address _tokenAddress, uint256 _amount) external{
        _update();
        VaultInfo memory tempVault = vaults[msg.sender];
        //require(healthFactorCheck < 1, "HEALTY, you don't need liquidation");
        require(tempVault.borrowUSDC >= _amount, "no");
        console.log("borrow", tempVault.borrowUSDC);
        require(tempVault.borrowUSDC*50/100 < _amount, "INSUFFICIENT_AMOUNT");
        uint price = tempVault.collateralETH * oracle.getPrice(address(0x0))/oracle.getPrice(_tokenAddress)*3/4;
        require(tempVault.borrowUSDC > price);
        require(_amount == tempVault.borrowUSDC/4);
        
        tempVault.borrowUSDC -= _amount;
        totalBorrowUSDC -= _amount;
        tempVault.collateralETH -= _amount * oracle.getPrice(_tokenAddress)/oracle.getPrice(address(0x0));
        vaults[msg.sender] = tempVault;

    }

    function withdraw(address _tokenAddress, uint256 _amount) external{
        _update();
        VaultInfo memory tempVault = vaults[msg.sender];
        uint256 availableWithdraw =  tempVault.borrowUSDC * oracle.getPrice(address(token)) / (oracle.getPrice(address(0x0)));
        // console.log("borrow", tempVault.borrowUSDC); //2000
        // console.log("usdc", oracle.getPrice(address(token))); //1
        // console.log("eth", oracle.getPrice(address(0x0))); //4000
        
        if(_tokenAddress == address(0)){
            require(tempVault.collateralETH >= _amount, "INSUFFICIENT_AMOUNT");
            require(address(this).balance >= _amount, "INSUFFICIENT_AMOUNT");
            // console.log("collateral", tempVault.collateralETH);
            // console.log("amount", _amount);
            // console.log("availableWithdraw", availableWithdraw);
            require((tempVault.collateralETH - _amount) * LTV / 100  >= availableWithdraw, "CANNOT_WITHDRAW");
            tempVault.collateralETH -= _amount;
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            require(success, "ERROR");  

        }
        else{
            require(tempVault.depositUSDC >= _amount,"INSUFFICIENT_AMOUNT");
            tempVault.depositUSDC -= _amount;
            totalDepositUSDC -= _amount;
            IERC20(token).transfer(msg.sender, _amount);
        }

        vaults[msg.sender] = tempVault;        
     
    }

    function getAccruedSupplyAmount(address _tokenAddress) external returns(uint256){
        return 1;
    }

    function _update() private  {
        vaults[msg.sender].availableBorrowETH2USDC = vaults[msg.sender].collateralETH * oracle.getPrice(address(0x0)) * LTV / (100*1e18) ;
        _updateInterest();
    }


    function _updateInterest() private {
        VaultInfo memory tempVault = vaults[msg.sender];
        uint256 blocktime = (block.number - tempVault.borrowBlockNumber);
        console.log("blocktime",blocktime);
        tempVault.borrowUSDC = _compound(vaults[msg.sender].borrowUSDC, 13881950033933776, blocktime);
        console.log("tempVault.borrowUSDC",tempVault.borrowUSDC);
        tempVault.borrowBlockNumber = block.number;
        vaults[msg.sender] = tempVault;
    }

    // function healthFactorCheck() external returns(uint256 healthFactor){
    //     VaultInfo memory temp = vaults[msg.sender];
    //     healthFactor = temp.collateralETH * LT / 100 * temp.borrowUSDC;

    // }

    function _compound (uint principal, uint ratio, uint n) public pure returns (uint) {
        return ABDKMath64x64.mulu (_pow (ABDKMath64x64.add (ABDKMath64x64.fromUInt (1), ABDKMath64x64.divu (ratio,10**22)),n),principal);
    }

    function _pow (int128 x, uint n) public pure returns (int128 r) {
        r = ABDKMath64x64.fromUInt (1);
        while (n > 0) {
            if (n % 2 == 1) {
            r = ABDKMath64x64.mul (r, x);
            n -= 1;
            } else {
            x = ABDKMath64x64.mul (x, x);
            n /= 2;
            }
        }
    }
}