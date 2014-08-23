#import "Environment.h"
#import "HttpManager.h"
#import "LocalizableText.h"
#import "NBAsYouTypeFormatter.h"
#import "PhoneNumber.h"
#import "PhoneNumberDirectoryFilterManager.h"
#import "PhoneNumberUtil.h"
#import "PreferencesUtil.h"
#import "PushManager.h"
#import "RegisterViewController.h"
#import "SignalUtil.h"
#import "SGNKeychainUtil.h"
#import "ThreadManager.h"
#import "Util.h"



#define REGISTER_VIEW_NUMBER 0
#define CHALLENGE_VIEW_NUMBER 1

#define COUNTRY_CODE_CHARACTER_MAX 3

#define SERVER_TIMEOUT_SECONDS 20
#define SMS_VERIFICATION_TIMEOUT_SECONDS 4*60
#define VOICE_VERIFICATION_COOLDOWN_SECONDS 4

#define IPHONE_BLUE [UIColor colorWithRed:22 green:173 blue:214 alpha:1]

@interface RegisterViewController () {
    NSMutableString *_enteredPhoneNumber;
    NSTimer* countdownTimer;
    NSDate *timeoutDate;
}

@end

@implementation RegisterViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self localizeButtonText];
    
    DDLogInfo(@"Opened Registration View");

    [self populateDefaultCountryNameAndCode];
    
    _scrollView.contentSize = _containerView.bounds.size;

    BOOL isRegisteredAlready = Environment.isRegistered;
    _registerCancelButton.hidden = !isRegisteredAlready;

    [self initializeKeyboardHandlers];
    [self setPlaceholderTextColor:[UIColor lightGrayColor]];
    _enteredPhoneNumber = [NSMutableString string];
}

+ (RegisterViewController*)registerViewController {
    RegisterViewController *viewController = [RegisterViewController new];
    viewController->life = [TOCCancelTokenSource new];
    viewController->registered = [TOCFutureSource futureSourceUntil:viewController->life.token];

    return viewController;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

- (void)setPlaceholderTextColor:(UIColor *)color {
    NSAttributedString *placeholder = _phoneNumberTextField.attributedPlaceholder;
    if (placeholder.length) {
        NSDictionary * attributes = [placeholder attributesAtIndex:0
                                                    effectiveRange:NULL];
        
        NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:attributes];
        newAttributes[NSForegroundColorAttributeName] = color;
        
        NSString *placeholderString = [placeholder string];
        _phoneNumberTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholderString
                                                                                      attributes:newAttributes];
    }
}

- (void)localizeButtonText {
    [_registerCancelButton      setTitle:TXT_CANCEL_TITLE forState:UIControlStateNormal];
    [_continueToWhisperButton   setTitle:CONTINUE_TO_WHISPER_TITLE forState:UIControlStateNormal];
    [_registerButton            setTitle:REGISTER_BUTTON_TITLE forState:UIControlStateNormal];
    [_challengeButton           setTitle:CHALLENGE_CODE_BUTTON_TITLE forState:UIControlStateNormal];
}

- (IBAction)registerCancelButtonTapped {
    [self dismissView];
}

- (void) dismissView {
    [self stopVoiceVerificationCountdownTimer];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)populateDefaultCountryNameAndCode {
    NSLocale *locale = [NSLocale currentLocale];
    NSString *countryCode = [locale objectForKey:NSLocaleCountryCode];
    NSNumber *cc = [NBPhoneNumberUtil.sharedInstance getCountryCodeForRegion:countryCode];
    
    _countryCodeLabel.text = [NSString stringWithFormat:@"%@%@",COUNTRY_CODE_PREFIX, cc];
    _countryNameLabel.text = [PhoneNumberUtil countryNameFromCountryCode:countryCode];
}

- (IBAction)changeNumberTapped {
    [self showViewNumber:REGISTER_VIEW_NUMBER];
}

- (IBAction)changeCountryCodeTapped {
    CountryCodeViewController *countryCodeController = [CountryCodeViewController new];
    countryCodeController.delegate = self;
    [self presentViewController:countryCodeController animated:YES completion:nil];
}

-(TOCFuture*) asyncRegister:(PhoneNumber*)phoneNumber untilCancelled:(TOCCancelToken*)cancelToken {
    [SGNKeychainUtil generateServerAuthPassword];
    [SGNKeychainUtil setLocalNumberTo:phoneNumber];
    
    TOCUntilOperation regStarter = ^TOCFuture *(TOCCancelToken* internalUntilCancelledToken) {
        HttpRequest *registerRequest = [HttpRequest httpRequestToStartRegistrationOfPhoneNumber];
       
        return [HttpManager asyncOkResponseFromMasterServer:registerRequest
                                            unlessCancelled:internalUntilCancelledToken
                                            andErrorHandler:[Environment errorNoter]];
    };
    TOCFuture *futurePhoneRegistrationStarted = [TOCFuture futureFromUntilOperation:[TOCFuture operationTry:regStarter]
                                                               withOperationTimeout:SERVER_TIMEOUT_SECONDS
                                                                              until:cancelToken];

    return [futurePhoneRegistrationStarted thenTry:^(id _) {
        [self showViewNumber:CHALLENGE_VIEW_NUMBER];
        [self.challengeNumberLabel setText:[phoneNumber description]];
        [_registerCancelButton removeFromSuperview];
        [self startVoiceVerificationCountdownTimer];
        self->futureChallengeAcceptedSource = [TOCFutureSource new];
        return futureChallengeAcceptedSource;
    }];

}

- (void)registerPhoneNumberTapped {
    NSString *phoneNumber = [NSString stringWithFormat:@"%@%@", _countryCodeLabel.text, _phoneNumberTextField.text];
    PhoneNumber* localNumber = [PhoneNumber tryParsePhoneNumberFromUserSpecifiedText:phoneNumber];
    if(localNumber==nil){ return; }
    
    [_phoneNumberTextField resignFirstResponder];

    TOCFuture* futureFinished = [self asyncRegister:localNumber untilCancelled:life.token];
    [_registerActivityIndicator startAnimating];
    _registerButton.enabled = NO;
    
    [futureFinished catchDo:^(id error) {
        NSError *err = ((NSError*)error);
        [_registerActivityIndicator stopAnimating];
        _registerButton.enabled = YES;
        
        DDLogError(@"Registration failed with information %@", err.description);
        
        UIAlertView *registrationErrorAV = [[UIAlertView alloc]initWithTitle:REGISTER_ERROR_ALERT_VIEW_TITLE message:REGISTER_ERROR_ALERT_VIEW_BODY delegate:nil cancelButtonTitle:REGISTER_ERROR_ALERT_VIEW_DISMISS otherButtonTitles:nil, nil];
        
        [registrationErrorAV show];
    }];
}

- (void)dismissTapped {
    [self dismissView];
}

- (void)verifyChallengeTapped {
    [_challengeTextField resignFirstResponder];
    _challengeButton.enabled = NO;
    [_challengeActivityIndicator startAnimating];
    
    HttpRequest *verifyRequest = [HttpRequest httpRequestToVerifyAccessToPhoneNumberWithChallenge:_challengeTextField.text];
    TOCFuture *futureDone = [HttpManager asyncOkResponseFromMasterServer:verifyRequest
                                                         unlessCancelled:nil
                                                         andErrorHandler:[Environment errorNoter]];
    
    [futureDone catchDo:^(id error) {
        if ([error isKindOfClass:[HttpResponse class]]) {
            HttpResponse* badResponse = error;
            if ([badResponse getStatusCode] == 401) {
                UIAlertView *incorrectChallengeCodeAV = [[UIAlertView alloc]initWithTitle:REGISTER_CHALLENGE_ALERT_VIEW_TITLE message:REGISTER_CHALLENGE_ALERT_VIEW_BODY delegate:nil cancelButtonTitle:REGISTER_CHALLENGE_ALERT_DISMISS otherButtonTitles:nil, nil];
                [incorrectChallengeCodeAV show];
                _challengeButton.enabled = YES;
                [_challengeActivityIndicator stopAnimating];
                return;
            }
        }
        _challengeButton.enabled = YES;
        [_challengeActivityIndicator stopAnimating];
        [Environment errorNoter](error, @"While Verifying Challenge.", NO);
    }];

    [futureDone thenDo:^(id result) {
        [futureChallengeAcceptedSource trySetResult:@YES];
    }];
    
    [futureChallengeAcceptedSource.future thenDo:^(id value) {
        [PushManager.sharedManager askForPushRegistrationWithSuccess:^{
            [Environment setRegistered:YES];
            [registered trySetResult:@YES];
            [[[Environment getCurrent] phoneDirectoryManager] forceUpdate];
            [self dismissView];
        } failure:^{
            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:REGISTER_ERROR_ALERT_VIEW_TITLE message:REGISTER_ERROR_ALERT_VIEW_BODY delegate:nil cancelButtonTitle:REGISTER_ERROR_ALERT_VIEW_DISMISS otherButtonTitles:nil, nil];
            [alertView show];
            _challengeButton.enabled = YES;
            [_challengeActivityIndicator stopAnimating];
        }];
    }];
    
}

- (void)showViewNumber:(NSInteger)viewNumber {

    if (viewNumber == REGISTER_VIEW_NUMBER) {
        [_registerActivityIndicator stopAnimating];
        _registerButton.enabled = YES;
    }
    
    [self stopVoiceVerificationCountdownTimer];
    
    [_scrollView setContentOffset:CGPointMake(_scrollView.frame.size.width*viewNumber, 0) animated:YES];
}

- (void)presentInvalidCountryCodeError {
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:REGISTER_CC_ERR_ALERT_VIEW_TITLE
                                                        message:REGISTER_CC_ERR_ALERT_VIEW_MESSAGE
                                                       delegate:nil
                                              cancelButtonTitle:REGISTER_CC_ERR_ALERT_VIEW_DISMISS
                                              otherButtonTitles:nil];
    [alertView show];
}

- (void) startVoiceVerificationCountdownTimer{
    [self.initiateVoiceVerificationButton.titleLabel setTextAlignment:NSTextAlignmentCenter];
    self.initiateVoiceVerificationButton.hidden = NO;
    
    NSTimeInterval smsTimeoutTimeInterval = SMS_VERIFICATION_TIMEOUT_SECONDS;
    
    NSDate *now = [[NSDate alloc] init];
    timeoutDate = [[NSDate alloc] initWithTimeInterval:smsTimeoutTimeInterval sinceDate:now];

    countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                      target:self
                                                    selector:@selector(countdowntimerFired)
                                                    userInfo:nil repeats:YES];
}

- (void) stopVoiceVerificationCountdownTimer{
    [countdownTimer invalidate];
}

- (void) countdowntimerFired {
    NSDate *now = [[NSDate alloc] init];
    
    NSCalendar *sysCalendar = [NSCalendar currentCalendar];
    unsigned int unitFlags = NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit;
    NSDateComponents *conversionInfo = [sysCalendar components:unitFlags fromDate:now  toDate:timeoutDate  options:0];
    NSString* timeLeft = [NSString stringWithFormat:@"%ld:%02ld",(long)[conversionInfo minute],(long)[conversionInfo second]];

    [self.voiceChallengeTextLabel setText:timeLeft];

    if (0 <= [now  compare:timeoutDate]) {
        [self initiateVoiceVerification];
    }
    
}

- (void) initiateVoiceVerification{
    [self stopVoiceVerificationCountdownTimer];
    TOCUntilOperation callStarter = ^TOCFuture *(TOCCancelToken* internalUntilCancelledToken) {
        HttpRequest* voiceVerifyReq = [HttpRequest httpRequestToStartRegistrationOfPhoneNumberWithVoice];
        
        [self.voiceChallengeTextLabel setText:@"Calling" ];
        return [HttpManager asyncOkResponseFromMasterServer:voiceVerifyReq
                                            unlessCancelled:internalUntilCancelledToken
                                            andErrorHandler:[Environment errorNoter]];
    };
    TOCFuture *futureVoiceVerificationStarted = [TOCFuture futureFromUntilOperation:[TOCFuture operationTry:callStarter]
                                                               withOperationTimeout:SERVER_TIMEOUT_SECONDS
                                                                              until:life.token];
    [futureVoiceVerificationStarted catchDo:^(id errorId) {
        HttpResponse* error = (HttpResponse*)errorId;
       [self.voiceChallengeTextLabel setText:[error getStatusText]];
    }];
    
    [futureVoiceVerificationStarted finallyTry:^(id _id) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, VOICE_VERIFICATION_COOLDOWN_SECONDS * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self.voiceChallengeTextLabel setText:@"Re-Call"];
        });
        
        return _id;
    }];
    
    
}

- (IBAction)initiateVoiceVerificationButtonHandler {
    [self initiateVoiceVerification];
}

#pragma mark - Keyboard notifications

- (void)initializeKeyboardHandlers{
    UITapGestureRecognizer *outsideTabRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboardFromAppropriateSubView)];
    [self.view addGestureRecognizer:outsideTabRecognizer];

    [self observeKeyboardNotifications];
    
}

-(void) dismissKeyboardFromAppropriateSubView {
    [self.view endEditing:NO];
}

- (void)observeKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    double duration = [[notification userInfo][UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        CGSize keyboardSize = [[notification userInfo][UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;;
        _scrollView.frame = CGRectMake(CGRectGetMinX(_scrollView.frame),
                                       CGRectGetMinY(_scrollView.frame)-keyboardSize.height,
                                       CGRectGetWidth(_scrollView.frame),
                                       CGRectGetHeight(_scrollView.frame));
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    double duration = [[notification userInfo][UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        _scrollView.frame = CGRectMake(CGRectGetMinX(_scrollView.frame),
                                       CGRectGetMinY(self.view.frame),
                                       CGRectGetWidth(_scrollView.frame),
                                       CGRectGetHeight(_scrollView.frame));
    }];
}

#pragma mark - CountryCodeViewControllerDelegate

- (void)countryCodeViewController:(CountryCodeViewController *)vc
             didSelectCountryCode:(NSString *)code
                       forCountry:(NSString *)country {
    _countryCodeLabel.text = code;
    _countryNameLabel.text = country;
    [self updatePhoneNumberFieldWithString:code cursorposition:_enteredPhoneNumber.length];
    [vc dismissViewControllerAnimated:YES completion:nil];
}

- (void)countryCodeViewControllerDidCancel:(CountryCodeViewController *)vc {
    [vc dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UITextFieldDelegate

- (NSUInteger) calculateLocationOffset:(NSUInteger)location {
    NSUInteger offset = 0, phonenumberposition = 0;
    for (NSUInteger i = 0; i < location; i++) {
        if ([_phoneNumberTextField.text characterAtIndex:i] != [_enteredPhoneNumber characterAtIndex:phonenumberposition]) {
            offset++;
        } else {
            phonenumberposition++;
        }
    }
    return offset;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range
                                                       replacementString:(NSString *)string {
    NSUInteger offset = [self calculateLocationOffset:range.location];
    unichar currentPoschar = 0;
    range.location -= offset;
    BOOL handleBackspace = range.length == 1;
    if (handleBackspace) {
        if ((range.location + offset) <  _phoneNumberTextField.text.length) {
            currentPoschar = [_phoneNumberTextField.text characterAtIndex:(range.location + offset)];
        }
        if ((currentPoschar < '0' || currentPoschar > '9') && currentPoschar != 0) {
            range.location--;
        }
        NSRange backspaceRange = NSMakeRange(range.location, 1);
        [_enteredPhoneNumber replaceCharactersInRange:backspaceRange withString:string];
        range.location++;
    } else {
        NSString* sanitizedString = [[string componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet ] invertedSet]] componentsJoinedByString:@""];
        NSMutableString* mutablePhoneNumber = [NSMutableString stringWithString:_enteredPhoneNumber];
        [mutablePhoneNumber insertString:sanitizedString atIndex:range.location];
        _enteredPhoneNumber = mutablePhoneNumber;
        if ((range.location + offset + 1) <  _phoneNumberTextField.text.length) {
            currentPoschar = [_phoneNumberTextField.text characterAtIndex:(range.location + offset + 1)];
        }
        if ((currentPoschar < '0' || currentPoschar > '9') && currentPoschar != 0) {
            range.location++;
        }
    }

    [self updatePhoneNumberFieldWithString:_enteredPhoneNumber cursorposition:range.location+offset];
    return NO;
}

-(void) updatePhoneNumberFieldWithString:(NSString*)input
                          cursorposition:(NSUInteger)cursorpos {
    NSString* result = [PhoneNumber bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber:_enteredPhoneNumber
                                                                    withSpecifiedCountryCodeString:_countryCodeLabel.text];
    cursorpos += result.length - _phoneNumberTextField.text.length;
    _phoneNumberTextField.text = result;
    UITextPosition *position = [_phoneNumberTextField positionFromPosition:[_phoneNumberTextField beginningOfDocument]
                                                                    offset:(NSInteger)cursorpos];
    [_phoneNumberTextField setSelectedTextRange:[_phoneNumberTextField textRangeFromPosition:position
                                                                                  toPosition:position]];
}

@end
