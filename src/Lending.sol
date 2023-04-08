// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.13;

// import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import "openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
// import "./DreamOracle.sol";
// import "forge-std/console.sol";
// import "./ABDKMath64x64.sol";


// interface IPriceOracle {
//     function getPrice(address token) external view returns (uint256);
//     function setPrice(address token, uint256 price) external;
// }

// /**
// ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
// - 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
// - 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
// - 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
// - 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
//  */

//  /**
//  1block -> 12sec
//  24hours -> 7200blocks -> 86400sec
//   */

// contract DreamAcademyLending{
//     struct LenderVault{
//         uint256 depositUSDC;
//         uint256 depositBlockNumber;
//         uint256 rewards;
//         uint256 userRewardPerTokenPaid;
//     }
//     struct BorrowerVault{
//         uint256 collateralETH;
//         uint256 availableBorrowETH2USDC;
//         uint256 borrowUSDC;
//         uint256 borrowBlockNumber;
//     }
//     uint256 constant LTV = 50;
//     uint256 constant LT = 75;
//     uint256 constant ONE_DAY_BLOCKS_TIME = 86400;
//     uint256 constant ONE_DAY_BLOCKS = 7200;
//     uint256 constant ONE_BLOCK_SEC = 12;

//     uint256 totalBorrowUSDC;
//     uint256 totalDepositUSDC;
//     uint256 totalUSDCUpdate;
//     uint256 public rewardPerTokenStored;
//     // Duration of rewards to be paid out (in seconds)


//     address token;
//     IPriceOracle oracle;
//     mapping(address => LenderVault) lenderVaults;
//     mapping(address => BorrowerVault) borrowerVaults;

//     constructor(IPriceOracle _oracle, address _token) {
//         token = _token;
//         oracle = _oracle;
//         borrowerVaults[msg.sender].borrowBlockNumber = block.number;
//         lenderVaults[msg.sender].depositBlockNumber = block.number;
//         totalUSDCUpdate = block.number;
//     }

//     modifier updateReward(address _account) {
//         rewardPerTokenStored = rewardPerToken();
//         updatedAt = _min(finishAt, block.number);

//         if (_account != address(0)) {
//             lenderVauls.rewards[_account] = earned(_account);
//             userRewardPerTokenPaid[_account] = rewardPerTokenStored;
//         }
//         _;
//     }

//     function initializeLendingProtocol(address _tokenAddress) external payable{
//         IERC20(_tokenAddress).transferFrom(msg.sender, address(this), msg.value);
//         totalDepositUSDC += msg.value;
//         totalUSDCUpdate = block.number;
//     }

//     /** deposi(입금)
//     ETH <-> USDC (2 cases)
//     1. _amount만큼 담보로 저장 (ETH: msg.value, USDC: _amount)
//     2. 해당 amount로 얼마 빌릴 수 있는지 구하기
//     3. VaultInfo update
//     */
//     function deposit(address _tokenAddress, uint256 _amount) external payable updateReward(msg.sender){
//         _update();
//         require(_tokenAddress == address(0x0) || _tokenAddress == token, "We do not support!");
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        
//         if(_tokenAddress == address(0x0)){ //담보로 맡길 ETH
//             require(msg.value != 0, "error");
//             require(msg.value == _amount, "false");
//             borrower.collateralETH += msg.value;
   
//         }
//         else{ //borrower에게 빌려줄 USDC 예금
//         //msg.sender의 balanceOf >= _amount
//             require(_amount!= 0, "INSUFFICIENT_AMOUNT");
//             require(IERC20(_tokenAddress).balanceOf(msg.sender) >= _amount, "INSUFFICIENT_DEPOSIT_AMOUNT");
//             IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount);
//             lender.depositUSDC += _amount;
//             totalDepositUSDC += _amount;
//             lender.depositBlockNumber = block.number;
//             totalDepositUSDC = block.number;
//         }
//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower;
//     }


//     /** borrow
//     1$ pegging -> 1USDC = 1$
//     1. msg.sender가 빌릴 수 있는양 계산(잔고x담보ETHxLTV) -> 빌릴 수 있는 양은 빌리려고 하는 양보다 많아야 함
//     담보 있을 때 예금도 빌리려는 만큼 있어야 하고, 빌리려는 만큼 담보도 있어야함
//     */
//     function borrow(address _tokenAddress, uint256 _amount) external{
//         _update();
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
        
//         require(borrower.availableBorrowETH2USDC >= _amount+borrower.borrowUSDC, "INSUFFICIENT_COLLATERAL_AMOUNT");

//         borrower.borrowUSDC += _amount;
//         totalBorrowUSDC += _amount;
//         borrower.borrowBlockNumber = block.number;
//         IERC20(token).transfer(msg.sender, _amount);
        
//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower;
//     }

//     function repay(address _tokenAddress, uint256 _amount) external{
//         _update();
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
//         require(borrower.borrowUSDC >= _amount, "INSUFFICIENT_REPAY_AMOUNT");

//         borrower.borrowUSDC -= _amount;
//         totalBorrowUSDC -= _amount;
//         IERC20(token).transferFrom(msg.sender, address(this), _amount);

//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower;
//     }

//     function liquidate(address _user, address _tokenAddress, uint256 _amount) external{
//         _update();
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 

//         require(borrower.borrowUSDC >= _amount, "no");
//         // require(borrower.collateralETH*50/100 < _amount, "INSUFFICIENT_AMOUNT");
//         uint price = borrower.collateralETH * oracle.getPrice(address(0x0))/oracle.getPrice(_tokenAddress)*3/4;
//         require(borrower.borrowUSDC > price);
//         require(_amount == borrower.borrowUSDC/4);
        
//         borrower.borrowUSDC -= _amount;
//         totalBorrowUSDC -= _amount;
//         borrower.collateralETH -= _amount * oracle.getPrice(_tokenAddress)/oracle.getPrice(address(0x0));
//         borrower.borrowBlockNumber = block.number*ONE_BLOCK_SEC;
//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower;

//     }

//     function withdraw(address _tokenAddress, uint256 _amount) external updateReward(msg.sender){
//         _update();
//         totalDepositUSDC = block.number;
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 

//         //uint256 availableWithdraw =  borrower.borrowUSDC * oracle.getPrice(address(token)) / (oracle.getPrice(address(0x0)));
//         uint256 availableWithdraw = getAccruedSupplyAmount(address(_tokenAddress));
        
//         if(_tokenAddress == address(0)){
//             require(borrower.collateralETH >= _amount, "INSUFFICIENT_AMOUNT");
//             require(address(this).balance >= _amount, "INSUFFICIENT_AMOUNT");
//             require((borrower.collateralETH - _amount) * LTV / 100  >= availableWithdraw, "CANNOT_WITHDRAW");
//             borrower.collateralETH -= _amount;
//             (bool success, ) = payable(msg.sender).call{value: _amount}("");
//             require(success, "ERROR");  

//         }
//         else{
//             require(IERC20(token).balanceOf(address(this)) >= _amount,"INSUFFICIENT_AMOUNT");
//             require(availableWithdraw >= _amount, "CANNOT_WITHDRAW");
//             lender.depositUSDC -= _amount * lender.depositUSDC / availableWithdraw;
//             totalDepositUSDC -= _amount;;
//             IERC20(token).transfer(msg.sender, _amount);
//         }

//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower;  
     
//     }
//     //getAccruedSupplyAmount 함수는 프로토콜에 예치한 사람이 공급한 유동성을 확인할 수 있는 함수입니다. ( 원금 + 대출이자로 얻은 수익 )
//     function getAccruedSupplyAmount(address _tokenAddress) external updateReward(msg.sender) returns(uint256){
        
//         uint256 interest = 0;
//         // uint remainingRewards += (block.number - totalUSDCUpdate) * totalDepositUSDC;
//         // rewardRate = (_amount + remainingRewards) / duration;

//         uint256 blocktime = block.number - totalUSDCUpdate;
//         interest = _compound(totalDepositUSDC, 13881950034147221897264156, blocktime/24 hours);//138819500341472218972641565
  
//         console.log("interest", interest);
//         uint256 accruedSupplyAmount = lenderVaults[msg.sender].depositUSDC + (lenderVaults[msg.sender].depositUSDC*interest / totalDepositUSDC);
//         console.log("accre", accruedSupplyAmount);
//         totalDepositUSDC = block.number;
//         //total 
//         return accruedSupplyAmount;
//     }

//     function _update() private  {
//         borrowerVaults[msg.sender].availableBorrowETH2USDC = borrowerVaults[msg.sender].collateralETH * oracle.getPrice(address(0x0)) * LTV / (100*1e18) ;
//         _updateInterest();
//     }


//     function _updateInterest() private {
//         LenderVault memory lender = lenderVaults[msg.sender]; 
//         BorrowerVault memory borrower = borrowerVaults[msg.sender]; 
//         uint256 BorrowBlocktime = block.number - borrower.borrowBlockNumber;
       
//         //tempVault.borrowUSDC = _compound(vaults[msg.sender].borrowUSDC, 13881950033933776, blocktime); //1.38819500341472218972641565 10^-7
//         borrower.borrowUSDC = _compound(borrower.borrowUSDC, 138819500339, BorrowBlocktime); //24시간 동안 붙는 이자 0.1%
//         //totalBorrowUSDC = _compound(totalBorrowUSDC, 13881950033933776, BorrowBlocktime); //24시간 동안 붙는 이자 0.1%
        
        
//         borrower.borrowBlockNumber = block.number;
        
//         lenderVaults[msg.sender] = lender;
//         borrowerVaults[msg.sender] = borrower; 
//     }    

//     function rewardPerToken() public view returns (uint) {
//         uint256 blocktime = block.number - totalUSDCUpdate;
//         if (totalDepositUSDC == 0) {
//             return rewardPerTokenStored;
//         }

//         return
//             rewardPerTokenStored +
//             (rewardRate * (block.number - totalUSDCUpdate) * 1e18) /
//             totalDepositUSDC;
//                 uint256 interest = 0;
//         // uint remainingRewards += (block.number - totalUSDCUpdate) * totalDepositUSDC;
//         // rewardRate = (_amount + remainingRewards) / duration;

//         uint256 blocktime = block.number - totalUSDCUpdate;
//         interest = _compound(totalDepositUSDC, 13881950034147221897264156, blocktime/24 hours);//138819500341472218972641565
  
//         console.log("interest", interest);
//         uint256 accruedSupplyAmount = lenderVaults[msg.sender].depositUSDC + (lenderVaults[msg.sender].depositUSDC*interest / totalDepositUSDC);
//         console.log("accre", accruedSupplyAmount);
//         totalDepositUSDC = block.number;
//     }

//     function earned(address _account) public view returns (uint) {
//         return
//             ((lenderVaults[_account].depositUSDC *
//                 (rewardPerToken() - lenderVaults[_account].userRewardPerTokenPaid)) / 1e18) +
//             lenderVaults[_account].rewards;
//     }

//     function _compound (uint principal, uint ratio, uint n) public pure returns (uint) {
//         return ABDKMath64x64.mulu (
//             _pow (
//                 ABDKMath64x64.add (
//                     ABDKMath64x64.fromUInt (1), ABDKMath64x64.divu (ratio,10**32)),n)
//             ,principal);
//     }

//     function _pow (int128 x, uint n) public pure returns (int128 r) {
//         r = ABDKMath64x64.fromUInt (1);
//         while (n > 0) {
//             if (n % 2 == 1) {
//             r = ABDKMath64x64.mul (r, x);
//             n -= 1;
//             } else {
//             x = ABDKMath64x64.mul (x, x);
//             n /= 2;
//             }
//         }
//     }

// }