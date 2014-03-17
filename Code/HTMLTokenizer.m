//  HTMLTokenizer.m
//
//  Public domain. https://github.com/nolanw/HTMLReader

#import "HTMLTokenizer.h"
#import "HTMLParser.h"
#import "HTMLPreprocessedInputStream.h"
#import "HTMLString.h"

@interface HTMLTagToken ()

- (void)appendLongCharacterToTagName:(UTF32Char)character;

@end

@interface HTMLDOCTYPEToken ()

- (void)appendLongCharacterToName:(UTF32Char)character;
- (void)appendStringToPublicIdentifier:(NSString *)string;
- (void)appendStringToSystemIdentifier:(NSString *)string;

@end

@interface HTMLCommentToken ()

- (void)appendString:(NSString *)string;
- (void)appendLongCharacter:(UTF32Char)character;

@end

@interface HTMLParser ()

@property (readonly, strong, nonatomic) HTMLElement *adjustedCurrentNode;

@end

@implementation HTMLTokenizer
{
    HTMLPreprocessedInputStream *_inputStream;
    HTMLTokenizerState _state;
    NSMutableArray *_tokenQueue;
    NSMutableString *_characterBuffer;
    id _currentToken;
    HTMLTokenizerState _sourceAttributeValueState;
    NSMutableString *_currentAttributeName;
    NSMutableString *_currentAttributeValue;
    NSMutableString *_temporaryBuffer;
    UTF32Char _additionalAllowedCharacter;
    NSString *_mostRecentEmittedStartTagName;
    BOOL _done;
}

- (id)initWithString:(NSString *)string
{
    if (!(self = [super init])) return nil;
    _inputStream = [[HTMLPreprocessedInputStream alloc] initWithString:string];
    __weak __typeof__(self) weakSelf = self;
    [_inputStream setErrorBlock:^(NSString *error) {
        [weakSelf emitParseError:@"%@", error];
    }];
    self.state = HTMLDataTokenizerState;
    _tokenQueue = [NSMutableArray new];
    _characterBuffer = [NSMutableString new];
    return self;
}

- (void)setLastStartTag:(NSString *)tagName
{
    _mostRecentEmittedStartTagName = [tagName copy];
}

- (void)dataState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in data state"];
        }
        return c == '&' || c == '<';
    }];
    [self emitCharacterTokenWithString:string];
    switch ([self consumeNextInputCharacter]) {
        case '&':
            return [self switchToState:HTMLCharacterReferenceInDataTokenizerState];
        case '<':
            return [self switchToState:HTMLTagOpenTokenizerState];
        case EOF:
            _done = YES;
            break;
    }
}

- (void)characterReferenceInDataState
{
    [self switchToState:HTMLDataTokenizerState];
    _additionalAllowedCharacter = (UTF32Char)EOF;
    NSString *data = [self attemptToConsumeCharacterReference];
    if (data) {
        [self emitCharacterTokenWithString:data];
    } else {
        [self emitCharacterTokenWithString:@"&"];
    }
}

- (void)RCDATAState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in RCDATA state"];
        }
        return c == '&' || c == '<';
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '&':
            return [self switchToState:HTMLCharacterReferenceInRCDATATokenizerState];
        case '<':
            return [self switchToState:HTMLRCDATALessThanSignTokenizerState];
        case EOF:
            _done = YES;
            break;
    }
}

- (void)characterReferenceInRCDATAState
{
    [self switchToState:HTMLRCDATATokenizerState];
    _additionalAllowedCharacter = (UTF32Char)EOF;
    NSString *data = [self attemptToConsumeCharacterReference];
    if (data) {
        [self emitCharacterTokenWithString:data];
    } else {
        [self emitCharacterTokenWithString:@"&"];
    }
}

- (void)RAWTEXTState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in RAWTEXT state"];
        }
        return c == '<';
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '<':
            return [self switchToState:HTMLRAWTEXTLessThanSignTokenizerState];
        case EOF:
            _done = YES;
            break;
    }
}

- (void)scriptDataState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in script data state"];
        }
        return c == '<';
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '<':
            return [self switchToState:HTMLScriptDataLessThanSignTokenizerState];
        case EOF:
            _done = YES;
            break;
    }
}

- (void)PLAINTEXTState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in PLAINTEXT state"];
        }
        return NO;
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    _done = YES;
}

static inline BOOL is_upper(NSInteger c)
{
    return c >= 'A' && c <= 'Z';
}

static inline BOOL is_lower(NSInteger c)
{
    return c >= 'a' && c <= 'z';
}

- (void)tagOpenState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '!':
            [self switchToState:HTMLMarkupDeclarationOpenTokenizerState];
            break;
        case '/':
            [self switchToState:HTMLEndTagOpenTokenizerState];
            break;
        case '?':
            [self emitParseError:@"Bogus ? in tag open state"];
            [self switchToState:HTMLBogusCommentTokenizerState];
            // SPEC We are to "emit a comment token whose data is the concatenation of all characters starting from and including the character that caused the state machine to switch into the bogus comment state...". This is effectively, but not explicitly, reconsuming the current input character.
            [_inputStream reconsumeCurrentInputCharacter];
            break;
        default:
            if (is_upper(c) || is_lower(c)) {
                _currentToken = [HTMLStartTagToken new];
                unichar toAppend = c + (is_upper(c) ? 0x0020 : 0);
                [_currentToken appendLongCharacterToTagName:toAppend];
                [self switchToState:HTMLTagNameTokenizerState];
            } else {
                [self emitParseError:@"Unexpected character in tag open state"];
                [self switchToState:HTMLDataTokenizerState];
                [self emitCharacterTokenWithString:@"<"];
                [self reconsume:c];
            }
            break;
    }
}

- (void)endTagOpenState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '>':
            [self emitParseError:@"Unexpected > in end tag open state"];
            [self switchToState:HTMLDataTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in end tag open state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCharacterTokenWithString:@"</"];
            [self reconsume:c];
            break;
        default:
            if (is_upper(c) || is_lower(c)) {
                _currentToken = [HTMLEndTagToken new];
                unichar toAppend = c + (is_upper(c) ? 0x0020 : 0);
                [_currentToken appendLongCharacterToTagName:toAppend];
                [self switchToState:HTMLTagNameTokenizerState];
            } else {
                [self emitParseError:@"Unexpected character in end tag open state"];
                [self switchToState:HTMLBogusCommentTokenizerState];
                // SPEC We are to "emit a comment token whose data is the concatenation of all characters starting from and including the character that caused the state machine to switch into the bogus comment state...". This is effectively, but not explicitly, reconsuming the current input character.
                [self reconsume:c];
            }
            break;
    }
}

- (void)tagNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLBeforeAttributeNameTokenizerState];
            break;
        case '/':
            [self switchToState:HTMLSelfClosingStartTagTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in tag name state"];
            [_currentToken appendLongCharacterToTagName:0xFFFD];
            break;
        case EOF:
            [self emitParseError:@"EOF in tag name state"];
            [self switchToState:HTMLDataTokenizerState];
            break;
        default:
            if (is_upper(c)) {
                [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
            } else {
                [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
            }
            break;
    }
}

- (void)RCDATALessThanSignState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '/') {
        _temporaryBuffer = [NSMutableString new];
        [self switchToState:HTMLRCDATAEndTagOpenTokenizerState];
    } else {
        [self switchToState:HTMLRCDATATokenizerState];
        [self emitCharacterTokenWithString:@"<"];
        [self reconsume:c];
    }
}

- (void)RCDATAEndTagOpenState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (is_upper(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLRCDATAEndTagNameTokenizerState];
    } else if (is_lower(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLRCDATAEndTagNameTokenizerState];
    } else {
        [self switchToState:HTMLRCDATATokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self reconsume:c];
    }
}

- (void)RCDATAEndTagNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLBeforeAttributeNameTokenizerState];
                return;
            }
            break;
        case '/':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLSelfClosingStartTagTokenizerState];
                return;
            }
            break;
        case '>':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLDataTokenizerState];
                [self emitCurrentToken];
                return;
            }
            break;
    }
    if (is_upper(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else if (is_lower(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else {
        [self switchToState:HTMLRCDATATokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self emitCharacterTokenWithString:_temporaryBuffer];
        [self reconsume:c];
    }
}

- (void)RAWTEXTLessThanSignState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '/') {
        _temporaryBuffer = [NSMutableString new];
        [self switchToState:HTMLRAWTEXTEndTagOpenTokenizerState];
    } else {
        [self switchToState:HTMLRAWTEXTTokenizerState];
        [self emitCharacterTokenWithString:@"<"];
        [self reconsume:c];
    }
}

- (void)RAWTEXTEndTagOpenState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (is_upper(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLRAWTEXTEndTagNameTokenizerState];
    } else if (is_lower(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLRAWTEXTEndTagNameTokenizerState];
    } else {
        [self switchToState:HTMLRAWTEXTTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self reconsume:c];
    }
}

- (void)RAWTEXTEndTagNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLBeforeAttributeNameTokenizerState];
                return;
            }
            break;
        case '/':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLSelfClosingStartTagTokenizerState];
                return;
            }
            break;
        case '>':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLDataTokenizerState];
                [self emitCurrentToken];
                return;
            }
            break;
    }
    if (is_upper(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else if (is_lower(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else {
        [self switchToState:HTMLRAWTEXTTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self emitCharacterTokenWithString:_temporaryBuffer];
        [self reconsume:c];
    }
}

- (void)scriptDataLessThanSignState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '/':
            _temporaryBuffer = [NSMutableString new];
            [self switchToState:HTMLScriptDataEndTagOpenTokenizerState];
            break;
        case '!':
            [self switchToState:HTMLScriptDataEscapeStartTokenizerState];
            [self emitCharacterTokenWithString:@"<!"];
            break;
        default:
            [self switchToState:HTMLScriptDataTokenizerState];
            [self emitCharacterTokenWithString:@"<"];
            [self reconsume:c];
            break;
    }
}

- (void)scriptDataEndTagOpenState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (is_upper(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLScriptDataEndTagNameTokenizerState];
    } else if (is_lower(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLScriptDataEndTagNameTokenizerState];
    } else {
        [self switchToState:HTMLScriptDataTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self reconsume:c];
    }
}

- (void)scriptDataEndTagNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLBeforeAttributeNameTokenizerState];
                return;
            }
            break;
        case '/':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLSelfClosingStartTagTokenizerState];
                return;
            }
            break;
        case '>':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLDataTokenizerState];
                [self emitCurrentToken];
                return;
            }
            break;
    }
    if (is_upper(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else if (is_lower(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else {
        [self switchToState:HTMLScriptDataTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self emitCharacterTokenWithString:_temporaryBuffer];
        [self reconsume:c];
    }
}

- (void)scriptDataEscapeStartState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '-') {
        [self switchToState:HTMLScriptDataEscapeStartDashTokenizerState];
        [self emitCharacterTokenWithString:@"-"];
    } else {
        [self switchToState:HTMLScriptDataTokenizerState];
        [self reconsume:c];
    }
}

- (void)scriptDataEscapeStartDashState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '-') {
        [self switchToState:HTMLScriptDataEscapedDashDashTokenizerState];
        [self emitCharacterTokenWithString:@"-"];
    } else {
        [self switchToState:HTMLScriptDataTokenizerState];
        [self reconsume:c];
    }
}

- (void)scriptDataEscapedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in script data escaped state"];
        }
        return c == '-' || c == '<';
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLScriptDataEscapedDashTokenizerState];
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            return [self switchToState:HTMLScriptDataEscapedLessThanSignTokenizerState];
        case EOF:
            [self switchToState:HTMLDataTokenizerState];
            [self emitParseError:@"EOF in script data escaped state"];
            [self reconsume:EOF];
            break;
    }
}

- (void)scriptDataEscapedDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLScriptDataEscapedDashDashTokenizerState];
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            [self switchToState:HTMLScriptDataEscapedLessThanSignTokenizerState];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in script data escaped dash state"];
            [self switchToState:HTMLScriptDataEscapedTokenizerState];
            [self emitCharacterTokenWithString:@"\uFFFD"];
            break;
        case EOF:
            [self emitParseError:@"EOF in script data escaped dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self switchToState:HTMLScriptDataEscapedTokenizerState];
            [self emitCharacterToken:(UTF32Char)c];
            break;
    }
}

- (void)scriptDataEscapedDashDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            [self switchToState:HTMLScriptDataEscapedLessThanSignTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLScriptDataTokenizerState];
            [self emitCharacterTokenWithString:@">"];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in script data escaped dash dash state"];
            [self switchToState:HTMLScriptDataEscapedTokenizerState];
            [self emitCharacterTokenWithString:@"\uFFFD"];
            break;
        case EOF:
            [self emitParseError:@"EOF in script data escaped dash dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self switchToState:HTMLScriptDataEscapedTokenizerState];
            [self emitCharacterToken:(UTF32Char)c];
            break;
    }
}

- (void)scriptDataEscapedLessThanSignState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '/':
            _temporaryBuffer = [NSMutableString new];
            [self switchToState:HTMLScriptDataEscapedEndTagOpenTokenizerState];
            break;
        default:
            if (is_upper(c)) {
                _temporaryBuffer = [NSMutableString new];
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c + 0x0020);
                [self switchToState:HTMLScriptDataDoubleEscapeStartTokenizerState];
                [self emitCharacterTokenWithString:@"<"];
                [self emitCharacterToken:(UTF32Char)c];
            } else if (is_lower(c)) {
                _temporaryBuffer = [NSMutableString new];
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
                [self switchToState:HTMLScriptDataDoubleEscapeStartTokenizerState];
                [self emitCharacterTokenWithString:@"<"];
                [self emitCharacterToken:(UTF32Char)c];
            } else {
                [self switchToState:HTMLScriptDataEscapedTokenizerState];
                [self emitCharacterTokenWithString:@"<"];
                [self reconsume:c];
            }
            break;
    }
}

- (void)scriptDataEscapedEndTagOpenState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (is_upper(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLScriptDataEscapedEndTagNameTokenizerState];
    } else if (is_lower(c)) {
        _currentToken = [HTMLEndTagToken new];
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
        [self switchToState:HTMLScriptDataEscapedEndTagNameTokenizerState];
    } else {
        [self switchToState:HTMLScriptDataEscapedTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self reconsume:c];
    }
}

- (void)scriptDataEscapedEndTagNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLBeforeAttributeNameTokenizerState];
                return;
            }
            break;
        case '/':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLSelfClosingStartTagTokenizerState];
                return;
            }
            break;
        case '>':
            if ([self currentTagIsAppropriateEndTagToken]) {
                [self switchToState:HTMLDataTokenizerState];
                [self emitCurrentToken];
                return;
            }
            break;
    }
    if (is_upper(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c + 0x0020];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else if (is_lower(c)) {
        [_currentToken appendLongCharacterToTagName:(UTF32Char)c];
        AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
    } else {
        [self switchToState:HTMLScriptDataEscapedTokenizerState];
        [self emitCharacterTokenWithString:@"</"];
        [self emitCharacterTokenWithString:_temporaryBuffer];
        [self reconsume:c];
    }
}

- (void)scriptDataDoubleEscapeStartState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
        case '/':
        case '>':
            if ([_temporaryBuffer isEqualToString:@"script"]) {
                [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            } else {
                [self switchToState:HTMLScriptDataEscapedTokenizerState];
            }
            [self emitCharacterToken:(UTF32Char)c];
            break;
        default:
            if (is_upper(c)) {
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c + 0x0020);
                [self emitCharacterToken:(UTF32Char)c];
            } else if (is_lower(c)) {
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
                [self emitCharacterToken:(UTF32Char)c];
            } else {
                [self switchToState:HTMLScriptDataEscapedTokenizerState];
                [self reconsume:c];
            }
            break;
    }
}

- (void)scriptDataDoubleEscapedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in script data double escaped state"];
        }
        return c == '-' || c == '<';
    }];
    [self emitCharacterTokenWithString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLScriptDataDoubleEscapedDashTokenizerState];
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            [self switchToState:HTMLScriptDataDoubleEscapedLessThanSignTokenizerState];
            [self emitCharacterTokenWithString:@"<"];
            break;
        case EOF:
            [self emitParseError:@"EOF in script data double escaped state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
    }
}

- (void)scriptDataDoubleEscapedDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLScriptDataDoubleEscapedDashDashTokenizerState];
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            [self switchToState:HTMLScriptDataDoubleEscapedLessThanSignTokenizerState];
            [self emitCharacterTokenWithString:@"<"];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in script data double escaped dash state"];
            [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            [self emitCharacterTokenWithString:@"\uFFFD"];
            break;
        case EOF:
            [self emitParseError:@"EOF in script data double escaped dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            [self emitCharacterToken:(UTF32Char)c];
            break;
    }
}

- (void)scriptDataDoubleEscapedDashDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self emitCharacterTokenWithString:@"-"];
            break;
        case '<':
            [self switchToState:HTMLScriptDataDoubleEscapedLessThanSignTokenizerState];
            [self emitCharacterTokenWithString:@"<"];
            break;
        case '>':
            [self switchToState:HTMLScriptDataTokenizerState];
            [self emitCharacterTokenWithString:@">"];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in script data double escaped dash dash state"];
            [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            [self emitCharacterTokenWithString:@"\uFFFD"];
            break;
        case EOF:
            [self emitParseError:@"EOF in script data double escaped dash dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            [self emitCharacterToken:(UTF32Char)c];
            break;
    }
}

- (void)scriptDataDoubleEscapedLessThanSignState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '/') {
        _temporaryBuffer = [NSMutableString new];
        [self switchToState:HTMLScriptDataDoubleEscapeEndTokenizerState];
        [self emitCharacterTokenWithString:@"/"];
    } else {
        [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
        [self reconsume:c];
    }
}

- (void)scriptDataDoubleEscapeEndState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
        case '/':
        case '>':
            if ([_temporaryBuffer isEqualToString:@"script"]) {
                [self switchToState:HTMLScriptDataEscapedTokenizerState];
            } else {
                [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
            }
            [self emitCharacterToken:(UTF32Char)c];
            break;
        default:
            if (is_upper(c)) {
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c + 0x0020);
                [self emitCharacterToken:(UTF32Char)c];
            } else if (is_lower(c)) {
                AppendLongCharacter(_temporaryBuffer, (UTF32Char)c);
                [self emitCharacterToken:(UTF32Char)c];
            } else {
                [self switchToState:HTMLScriptDataDoubleEscapedTokenizerState];
                [self reconsume:c];
            }
            break;
    }
}

- (void)beforeAttributeNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '/':
            [self switchToState:HTMLSelfClosingStartTagTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in before attribute name state"];
            _currentAttributeName = [NSMutableString new];
            AppendLongCharacter(_currentAttributeName, 0xFFFD);
            [self switchToState:HTMLAttributeNameTokenizerState];
            break;
        case '"':
        case '\'':
        case '<':
        case '=':
            [self emitParseError:@"Unexpected %c in before attribute name state", (char)c];
            goto anythingElse;
        case EOF:
            [self emitParseError:@"EOF in before attribute name state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
        anythingElse:
            _currentAttributeName = [NSMutableString new];
            if (is_upper(c)) {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c + 0x0020);
            } else {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c);
            }
            [self switchToState:HTMLAttributeNameTokenizerState];
            break;
    }
}

- (void)attributeNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLAfterAttributeNameTokenizerState];
            break;
        case '/':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLSelfClosingStartTagTokenizerState];
            break;
        case '=':
            [self switchToState:HTMLBeforeAttributeValueTokenizerState];
            break;
        case '>':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in attribute name state"];
            AppendLongCharacter(_currentAttributeName, 0xFFFD);
            break;
        case '"':
        case '\'':
        case '<':
            [self emitParseError:@"Unexpected %c in attribute name state", (char)c];
            goto anythingElse;
        case EOF:
            [self emitParseError:@"EOF in attribute name state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
        anythingElse:
            if (is_upper(c)) {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c + 0x0020);
            } else {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c);
            }
            break;
    }
}

- (void)afterAttributeNameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '/':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLSelfClosingStartTagTokenizerState];
            break;
        case '=':
            [self switchToState:HTMLBeforeAttributeValueTokenizerState];
            break;
        case '>':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in after attribute name state"];
            [self addCurrentAttributeToCurrentToken];
            _currentAttributeName = [NSMutableString new];
            AppendLongCharacter(_currentAttributeName, 0xFFFD);
            [self switchToState:HTMLAttributeNameTokenizerState];
            break;
        case '"':
        case '\'':
        case '<':
            [self emitParseError:@"Unexpected %c in after attribute name state", (char)c];
            goto anythingElse;
        case EOF:
            [self emitParseError:@"EOF in after attribute name state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
        anythingElse:
            [self addCurrentAttributeToCurrentToken];
            _currentAttributeName = [NSMutableString new];
            if (is_upper(c)) {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c + 0x0020);
            } else {
                AppendLongCharacter(_currentAttributeName, (UTF32Char)c);
            }
            [self switchToState:HTMLAttributeNameTokenizerState];
            break;
    }
}

- (void)beforeAttributeValueState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '"':
            _currentAttributeValue = [NSMutableString new];
            [self switchToState:HTMLAttributeValueDoubleQuotedTokenizerState];
            break;
        case '&':
            _currentAttributeValue = [NSMutableString new];
            [self switchToState:HTMLAttributeValueUnquotedTokenizerState];
            [self reconsume:c];
            break;
        case '\'':
            _currentAttributeValue = [NSMutableString new];
            [self switchToState:HTMLAttributeValueSingleQuotedTokenizerState];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in before attribute value state"];
            _currentAttributeValue = [NSMutableString new];
            AppendLongCharacter(_currentAttributeValue, 0xFFFD);
            [self switchToState:HTMLAttributeValueUnquotedTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in before attribute value state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '<':
        case '=':
        case '`':
            [self emitParseError:@"Unexpected %c in before attribute value state", (char)c];
            goto anythingElse;
        case EOF:
            [self emitParseError:@"EOF in before attribute value state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
        anythingElse:
            _currentAttributeValue = [NSMutableString new];
            AppendLongCharacter(_currentAttributeValue, (UTF32Char)c);
            [self switchToState:HTMLAttributeValueUnquotedTokenizerState];
            break;
    }
}

- (void)attributeValueDoubleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in attribute value double quoted state"];
        }
        return c == '"' || c == '&';
    }] ?: @"";
    [_currentAttributeValue appendString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '"':
            return [self switchToState:HTMLAfterAttributeValueQuotedTokenizerState];
        case '&':
            [self switchToState:HTMLCharacterReferenceInAttributeValueTokenizerState];
            _additionalAllowedCharacter = '"';
            _sourceAttributeValueState = HTMLAttributeValueDoubleQuotedTokenizerState;
            break;
        case EOF:
            [self emitParseError:@"EOF in attribute value double quoted state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
    }
}

- (void)attributeValueSingleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in attribute value single quoted state"];
        }
        return c == '\'' || c == '&';
    }] ?: @"";
    [_currentAttributeValue appendString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '\'':
            return [self switchToState:HTMLAfterAttributeValueQuotedTokenizerState];
        case '&':
            [self switchToState:HTMLCharacterReferenceInAttributeValueTokenizerState];
            _additionalAllowedCharacter = '\'';
            _sourceAttributeValueState = HTMLAttributeValueSingleQuotedTokenizerState;
            break;
        case EOF:
            [self emitParseError:@"EOF in attribute value single quoted state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
    }
}

- (void)attributeValueUnquotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in attribute value unquoted state"];
        } else if (c == '"' || c == '\'' || c == '<' || c == '=' || c == '`') {
            [self emitParseError:@"Unexpected %c in attribute value unquoted state", (char)c];
        }
        return is_whitespace(c) || c == '&' || c == '>';
    }] ?: @"";
    [_currentAttributeValue appendString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self addCurrentAttributeToCurrentToken];
            return [self switchToState:HTMLBeforeAttributeNameTokenizerState];
        case '&':
            [self switchToState:HTMLCharacterReferenceInAttributeValueTokenizerState];
            _additionalAllowedCharacter = '>';
            _sourceAttributeValueState = HTMLAttributeValueUnquotedTokenizerState;
            break;
        case '>':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in attribute value unquoted state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
    }
}

- (void)characterReferenceInAttributeValueState
{
    NSString *characters = [self attemptToConsumeCharacterReferenceAsPartOfAnAttribute];
    if (characters) {
        [_currentAttributeValue appendString:characters];
    } else {
        [_currentAttributeValue appendString:@"&"];
    }
    [self switchToState:_sourceAttributeValueState];
}

- (void)afterAttributeValueQuotedState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLBeforeAttributeNameTokenizerState];
            break;
        case '/':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLSelfClosingStartTagTokenizerState];
            break;
        case '>':
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in after attribute value quoted state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in after attribute value quoted state"];
            [self addCurrentAttributeToCurrentToken];
            [self switchToState:HTMLBeforeAttributeNameTokenizerState];
            [self reconsume:c];
            break;
    }
}

- (void)selfClosingStartTagState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '>':
            [_currentToken setSelfClosingFlag:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in self closing start tag state"];
            [self switchToState:HTMLDataTokenizerState];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in self closing start tag state"];
            [self switchToState:HTMLBeforeAttributeNameTokenizerState];
            [self reconsume:c];
            break;
    }
}

- (void)bogusCommentState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        return c == '>';
    }];
    _currentToken = [[HTMLCommentToken alloc] initWithData:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    [self emitCurrentToken];
    [self switchToState:HTMLDataTokenizerState];
    if ([self consumeNextInputCharacter] == (UTF32Char)EOF) {
        [self reconsume:EOF];
    }
}

- (void)markupDeclarationOpenState
{
    if ([_inputStream consumeString:@"--" matchingCase:YES]) {
        _currentToken = [[HTMLCommentToken alloc] initWithData:@""];
        [self switchToState:HTMLCommentStartTokenizerState];
    } else if (_parser.adjustedCurrentNode.namespace != HTMLNamespaceHTML && [_inputStream consumeString:@"[CDATA[" matchingCase:YES]) {
        [self switchToState:HTMLCDATASectionTokenizerState];
    } else if ([_inputStream consumeString:@"DOCTYPE" matchingCase:NO]) {
        [self switchToState:HTMLDOCTYPETokenizerState];
    } else {
        [self emitParseError:@"Bogus character in markup declaration open state"];
        [self switchToState:HTMLBogusCommentTokenizerState];
    }
}

- (void)commentStartState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLCommentStartDashTokenizerState];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in comment start state"];
            [_currentToken appendLongCharacter:0xFFFD];
            [self switchToState:HTMLCommentTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in comment start state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in comment start state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [_currentToken appendLongCharacter:(UTF32Char)c];
            [self switchToState:HTMLCommentTokenizerState];
            break;
    }
}

- (void)commentStartDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLCommentEndTokenizerState];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in comment start dash state"];
            [_currentToken appendLongCharacter:'-'];
            [_currentToken appendLongCharacter:0xFFFD];
            [self switchToState:HTMLCommentTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in comment start dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in comment start dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [_currentToken appendLongCharacter:'-'];
            [_currentToken appendLongCharacter:(UTF32Char)c];
            [self switchToState:HTMLCommentTokenizerState];
            break;
    }
}

- (void)commentState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in comment state"];
        }
        return c == '-';
    }];
    [_currentToken appendString:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '-':
            return [self switchToState:HTMLCommentEndDashTokenizerState];
        case EOF:
            [self emitParseError:@"EOF in comment state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
    }
}

- (void)commentEndDashState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [self switchToState:HTMLCommentEndTokenizerState];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in comment end dash state"];
            [_currentToken appendLongCharacter:'-'];
            [_currentToken appendLongCharacter:0xFFFD];
            [self switchToState:HTMLCommentTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in comment end dash state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [_currentToken appendLongCharacter:'-'];
            [_currentToken appendLongCharacter:(UTF32Char)c];
            [self switchToState:HTMLCommentTokenizerState];
            break;
    }
}

- (void)commentEndState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in comment end state"];
            [_currentToken appendString:@"--"];
            [_currentToken appendLongCharacter:0xFFFD];
            [self switchToState:HTMLCommentTokenizerState];
            break;
        case '!':
            [self emitParseError:@"Unexpected ! in comment end state"];
            [self switchToState:HTMLCommentEndBangTokenizerState];
            break;
        case '-':
            [self emitParseError:@"Unexpected - in comment end state"];
            [_currentToken appendLongCharacter:'-'];
            break;
        case EOF:
            [self emitParseError:@"EOF in comment end state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in comment end state"];
            [_currentToken appendString:@"--"];
            [_currentToken appendLongCharacter:(UTF32Char)c];
            [self switchToState:HTMLCommentTokenizerState];
            break;
    }
}

- (void)commentEndBangState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '-':
            [_currentToken appendString:@"--!"];
            [self switchToState:HTMLCommentEndDashTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in comment end bang state"];
            [_currentToken appendString:@"--!\uFFFD"];
            [self switchToState:HTMLCommentTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in comment end bang state"];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [_currentToken appendString:@"--!"];
            [_currentToken appendLongCharacter:(UTF32Char)c];
            [self switchToState:HTMLCommentTokenizerState];
            break;
    }
}

- (void)DOCTYPEState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLBeforeDOCTYPENameTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE state"];
            [self switchToState:HTMLDataTokenizerState];
            _currentToken = [HTMLDOCTYPEToken new];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in DOCTYPE state"];
            [self switchToState:HTMLBeforeDOCTYPENameTokenizerState];
            [self reconsume:c];
            break;
    }
}

- (void)beforeDOCTYPENameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in before DOCTYPE name state"];
            _currentToken = [HTMLDOCTYPEToken new];
            [_currentToken appendLongCharacterToName:0xFFFD];
            [self switchToState:HTMLDOCTYPENameTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in before DOCTYPE name state"];
            _currentToken = [HTMLDOCTYPEToken new];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in before DOCTYPE name state"];
            [self switchToState:HTMLDataTokenizerState];
            _currentToken = [HTMLDOCTYPEToken new];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            _currentToken = [HTMLDOCTYPEToken new];
            if (is_upper(c)) {
                [_currentToken appendLongCharacterToName:(UTF32Char)c + 0x0020];
            } else {
                [_currentToken appendLongCharacterToName:(UTF32Char)c];
            }
            [self switchToState:HTMLDOCTYPENameTokenizerState];
            break;
    }
}

- (void)DOCTYPENameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLAfterDOCTYPENameTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '\0':
            [self emitParseError:@"U+0000 NULL in DOCTYPE name state"];
            [_currentToken appendLongCharacterToName:0xFFFD];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE name state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            if (is_upper(c)) {
                [_currentToken appendLongCharacterToName:(UTF32Char)c + 0x0020];
            } else {
                [_currentToken appendLongCharacterToName:(UTF32Char)c];
            }
            break;
    }
}

- (void)afterDOCTYPENameState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in after DOCTYPE name state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        case 'P':
        case 'p':
            if ([_inputStream consumeString:@"UBLIC" matchingCase:NO]) {
                [self switchToState:HTMLAfterDOCTYPEPublicKeywordTokenizerState];
            } else {
                goto anythingElse;
            }
            break;
        case 'S':
        case 's':
            if ([_inputStream consumeString:@"YSTEM" matchingCase:NO]) {
                [self switchToState:HTMLAfterDOCTYPESystemKeywordTokenizerState];
            } else {
                goto anythingElse;
            }
            break;
        default:
        anythingElse:
                [self emitParseError:@"Unexpected character in after DOCTYPE name state"];
                [_currentToken setForceQuirks:YES];
                [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)afterDOCTYPEPublicKeywordState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLBeforeDOCTYPEPublicIdentifierTokenizerState];
            break;
        case '"':
            [self emitParseError:@"Unexpected \" in after DOCTYPE public keyword state"];
            [_currentToken setPublicIdentifier:@""];
            [self switchToState:HTMLDOCTYPEPublicIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [self emitParseError:@"Unexpected ' in after DOCTYPE public keyword state"];
            [_currentToken setPublicIdentifier:@""];
            [self switchToState:HTMLDOCTYPEPublicIdentifierSingleQuotedTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in after DOCTYPE public keyword state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in after DOCTYPE public keyword state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in after DOCTYPE public keyword state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)beforeDOCTYPEPublicIdentifierState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '"':
            [_currentToken setPublicIdentifier:@""];
            [self switchToState:HTMLDOCTYPEPublicIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [_currentToken setPublicIdentifier:@""];
            [self switchToState:HTMLDOCTYPEPublicIdentifierSingleQuotedTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in before DOCTYPE public identifier state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in before DOCTYPE public identifier state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in before DOCTYPE public identifier state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)DOCTYPEPublicIdentifierDoubleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in DOCTYPE public identifier double quoted state"];
        }
        return c == '"' || c == '>';
    }];
    [_currentToken appendStringToPublicIdentifier:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '"':
            return [self switchToState:HTMLAfterDOCTYPEPublicIdentifierTokenizerState];
        case '>':
            [self emitParseError:@"Unexpected > in DOCTYPE public identifier double quoted state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE public identifier double quoted state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
    }
}

- (void)DOCTYPEPublicIdentifierSingleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in DOCTYPE public identifier single quoted state"];
        }
        return c == '\'' || c == '>';
    }];
    [_currentToken appendStringToPublicIdentifier:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '\'':
            return [self switchToState:HTMLAfterDOCTYPEPublicIdentifierTokenizerState];
        case '>':
            [self emitParseError:@"Unexpected > in DOCTYPE public identifier single quoted state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE public identifier single quoted state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
    }
}

- (void)afterDOCTYPEPublicIdentifierState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLBetweenDOCTYPEPublicAndSystemIdentifiersTokenizerState];
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '"':
            [self emitParseError:@"Unexpected \" in after DOCTYPE public identifier state"];
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [self emitParseError:@"Unexpected ' in after DOCTYPE public identifier state"];
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierSingleQuotedTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in after DOCTYPE public identifier state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in after DOCTYPE public identifier state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)betweenDOCTYPEPublicAndSystemIdentifiersState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case '"':
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierSingleQuotedTokenizerState];
            break;
        case EOF:
            [self emitParseError:@"EOF in between DOCTYPE public and system identifiers state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in between DOCTYPE public and system identifiers state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)afterDOCTYPESystemKeywordState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            [self switchToState:HTMLBeforeDOCTYPESystemIdentifierTokenizerState];
            break;
        case '"':
            [self emitParseError:@"Unexpected \" in after DOCTYPE system keyword state"];
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [self emitParseError:@"Unexpected ' in after DOCTYPE system keyword state"];
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierSingleQuotedTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in after DOCTYPE system keyword state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in after DOCTYPE system keyword state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in after DOCTYPE system keyword state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)beforeDOCTYPESystemIdentifierState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '"':
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierDoubleQuotedTokenizerState];
            break;
        case '\'':
            [_currentToken setSystemIdentifier:@""];
            [self switchToState:HTMLDOCTYPESystemIdentifierSingleQuotedTokenizerState];
            break;
        case '>':
            [self emitParseError:@"Unexpected > in before DOCTYPE system identifier state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in before DOCTYPE system identifier state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in before DOCTYPE system identifier state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)DOCTYPESystemIdentifierDoubleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in DOCTYPE system identifier double quoted state"];
        }
        return c == '"' || c == '>';
    }];
    [_currentToken appendStringToSystemIdentifier:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '"':
            return [self switchToState:HTMLAfterDOCTYPESystemIdentifierTokenizerState];
        case '>':
            [self emitParseError:@"Unexpected > in DOCTYPE system identifier double quoted state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE system identifier double quoted state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
    }
}

- (void)DOCTYPESystemIdentifierSingleQuotedState
{
    NSString *string = [self consumeCharactersUpToFirstPassingTest:^BOOL(UTF32Char c) {
        if (c == '\0') {
            [self emitParseError:@"U+0000 NULL in DOCTYPE system identifier single quoted state"];
        }
        return c == '\'' || c == '>';
    }];
    [_currentToken appendStringToSystemIdentifier:[string stringByReplacingOccurrencesOfString:@"\0" withString:@"\uFFFD"]];
    switch ([self consumeNextInputCharacter]) {
        case '\'':
            return [self switchToState:HTMLAfterDOCTYPESystemIdentifierTokenizerState];
        case '>':
            [self emitParseError:@"Unexpected > in DOCTYPE system identifier single quoted state"];
            [_currentToken setForceQuirks:YES];
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in DOCTYPE system identifier single quoted state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
    }
}

- (void)afterDOCTYPESystemIdentifierState
{
    UTF32Char c;
    switch (c = [self consumeNextInputCharacter]) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
            break;
        case '>':
            [self switchToState:HTMLDataTokenizerState];
            [self emitCurrentToken];
            break;
        case EOF:
            [self emitParseError:@"EOF in after DOCTYPE system identifier state"];
            [self switchToState:HTMLDataTokenizerState];
            [_currentToken setForceQuirks:YES];
            [self emitCurrentToken];
            [self reconsume:EOF];
            break;
        default:
            [self emitParseError:@"Unexpected character in after DOCTYPE system identifier state"];
            [self switchToState:HTMLBogusDOCTYPETokenizerState];
            break;
    }
}

- (void)bogusDOCTYPEState
{
    UTF32Char c = [self consumeNextInputCharacter];
    if (c == '>') {
        [self switchToState:HTMLDataTokenizerState];
        [self emitCurrentToken];
    } else if (c == (UTF32Char)EOF) {
        [self switchToState:HTMLDataTokenizerState];
        [self emitCurrentToken];
        [self reconsume:EOF];
    }
}

- (void)CDATASectionState
{
    [self switchToState:HTMLDataTokenizerState];
    NSInteger squareBracketsSeen = 0;
    for (;;) {
        UTF32Char c = [self consumeNextInputCharacter];
        if (c == ']' && squareBracketsSeen < 2) {
            squareBracketsSeen++;
        } else if (c == ']' && squareBracketsSeen == 2) {
            [self emitCharacterTokenWithString:@"]"];
        } else if (c == '>' && squareBracketsSeen == 2) {
            break;
        } else {
            for (NSInteger i = 0; i < squareBracketsSeen; i++) {
                [self emitCharacterTokenWithString:@"]"];
            }
            if (c == (UTF32Char)EOF) {
                [self reconsume:c];
                break;
            }
            squareBracketsSeen = 0;
            [self emitCharacterToken:(UTF32Char)c];
        }
    }
}

- (void)resume
{
    switch (self.state) {
        case HTMLDataTokenizerState:
            return [self dataState];
        case HTMLCharacterReferenceInDataTokenizerState:
            return [self characterReferenceInDataState];
        case HTMLRCDATATokenizerState:
            return [self RCDATAState];
        case HTMLCharacterReferenceInRCDATATokenizerState:
            return [self characterReferenceInRCDATAState];
        case HTMLRAWTEXTTokenizerState:
            return [self RAWTEXTState];
        case HTMLScriptDataTokenizerState:
            return [self scriptDataState];
        case HTMLPLAINTEXTTokenizerState:
            return [self PLAINTEXTState];
        case HTMLTagOpenTokenizerState:
            return [self tagOpenState];
        case HTMLEndTagOpenTokenizerState:
            return [self endTagOpenState];
        case HTMLTagNameTokenizerState:
            return [self tagNameState];
        case HTMLRCDATALessThanSignTokenizerState:
            return [self RCDATALessThanSignState];
        case HTMLRCDATAEndTagOpenTokenizerState:
            return [self RCDATAEndTagOpenState];
        case HTMLRCDATAEndTagNameTokenizerState:
            return [self RCDATAEndTagNameState];
        case HTMLRAWTEXTLessThanSignTokenizerState:
            return [self RAWTEXTLessThanSignState];
        case HTMLRAWTEXTEndTagOpenTokenizerState:
            return [self RAWTEXTEndTagOpenState];
        case HTMLRAWTEXTEndTagNameTokenizerState:
            return [self RAWTEXTEndTagNameState];
        case HTMLScriptDataLessThanSignTokenizerState:
            return [self scriptDataLessThanSignState];
        case HTMLScriptDataEndTagOpenTokenizerState:
            return [self scriptDataEndTagOpenState];
        case HTMLScriptDataEndTagNameTokenizerState:
            return [self scriptDataEndTagNameState];
        case HTMLScriptDataEscapeStartTokenizerState:
            return [self scriptDataEscapeStartState];
        case HTMLScriptDataEscapeStartDashTokenizerState:
            return [self scriptDataEscapeStartDashState];
        case HTMLScriptDataEscapedTokenizerState:
            return [self scriptDataEscapedState];
        case HTMLScriptDataEscapedDashTokenizerState:
            return [self scriptDataEscapedDashState];
        case HTMLScriptDataEscapedDashDashTokenizerState:
            return [self scriptDataEscapedDashDashState];
        case HTMLScriptDataEscapedLessThanSignTokenizerState:
            return [self scriptDataEscapedLessThanSignState];
        case HTMLScriptDataEscapedEndTagOpenTokenizerState:
            return [self scriptDataEscapedEndTagOpenState];
        case HTMLScriptDataEscapedEndTagNameTokenizerState:
            return [self scriptDataEscapedEndTagNameState];
        case HTMLScriptDataDoubleEscapeStartTokenizerState:
            return [self scriptDataDoubleEscapeStartState];
        case HTMLScriptDataDoubleEscapedTokenizerState:
            return [self scriptDataDoubleEscapedState];
        case HTMLScriptDataDoubleEscapedDashTokenizerState:
            return [self scriptDataDoubleEscapedDashState];
        case HTMLScriptDataDoubleEscapedDashDashTokenizerState:
            return [self scriptDataDoubleEscapedDashDashState];
        case HTMLScriptDataDoubleEscapedLessThanSignTokenizerState:
            return [self scriptDataDoubleEscapedLessThanSignState];
        case HTMLScriptDataDoubleEscapeEndTokenizerState:
            return [self scriptDataDoubleEscapeEndState];
        case HTMLBeforeAttributeNameTokenizerState:
            return [self beforeAttributeNameState];
        case HTMLAttributeNameTokenizerState:
            return [self attributeNameState];
        case HTMLAfterAttributeNameTokenizerState:
            return [self afterAttributeNameState];
        case HTMLBeforeAttributeValueTokenizerState:
            return [self beforeAttributeValueState];
        case HTMLAttributeValueDoubleQuotedTokenizerState:
            return [self attributeValueDoubleQuotedState];
        case HTMLAttributeValueSingleQuotedTokenizerState:
            return [self attributeValueSingleQuotedState];
        case HTMLAttributeValueUnquotedTokenizerState:
            return [self attributeValueUnquotedState];
        case HTMLCharacterReferenceInAttributeValueTokenizerState:
            return [self characterReferenceInAttributeValueState];
        case HTMLAfterAttributeValueQuotedTokenizerState:
            return [self afterAttributeValueQuotedState];
        case HTMLSelfClosingStartTagTokenizerState:
            return [self selfClosingStartTagState];
        case HTMLBogusCommentTokenizerState:
            return [self bogusCommentState];
        case HTMLMarkupDeclarationOpenTokenizerState:
            return [self markupDeclarationOpenState];
        case HTMLCommentStartTokenizerState:
            return [self commentStartState];
        case HTMLCommentStartDashTokenizerState:
            return [self commentStartDashState];
        case HTMLCommentTokenizerState:
            return [self commentState];
        case HTMLCommentEndDashTokenizerState:
            return [self commentEndDashState];
        case HTMLCommentEndTokenizerState:
            return [self commentEndState];
        case HTMLCommentEndBangTokenizerState:
            return [self commentEndBangState];
        case HTMLDOCTYPETokenizerState:
            return [self DOCTYPEState];
        case HTMLBeforeDOCTYPENameTokenizerState:
            return [self beforeDOCTYPENameState];
        case HTMLDOCTYPENameTokenizerState:
            return [self DOCTYPENameState];
        case HTMLAfterDOCTYPENameTokenizerState:
            return [self afterDOCTYPENameState];
        case HTMLAfterDOCTYPEPublicKeywordTokenizerState:
            return [self afterDOCTYPEPublicKeywordState];
        case HTMLBeforeDOCTYPEPublicIdentifierTokenizerState:
            return [self beforeDOCTYPEPublicIdentifierState];
        case HTMLDOCTYPEPublicIdentifierDoubleQuotedTokenizerState:
            return [self DOCTYPEPublicIdentifierDoubleQuotedState];
        case HTMLDOCTYPEPublicIdentifierSingleQuotedTokenizerState:
            return [self DOCTYPEPublicIdentifierSingleQuotedState];
        case HTMLAfterDOCTYPEPublicIdentifierTokenizerState:
            return [self afterDOCTYPEPublicIdentifierState];
        case HTMLBetweenDOCTYPEPublicAndSystemIdentifiersTokenizerState:
            return [self betweenDOCTYPEPublicAndSystemIdentifiersState];
        case HTMLAfterDOCTYPESystemKeywordTokenizerState:
            return [self afterDOCTYPESystemKeywordState];
        case HTMLBeforeDOCTYPESystemIdentifierTokenizerState:
            return [self beforeDOCTYPESystemIdentifierState];
        case HTMLDOCTYPESystemIdentifierDoubleQuotedTokenizerState:
            return [self DOCTYPESystemIdentifierDoubleQuotedState];
        case HTMLDOCTYPESystemIdentifierSingleQuotedTokenizerState:
            return [self DOCTYPESystemIdentifierSingleQuotedState];
        case HTMLAfterDOCTYPESystemIdentifierTokenizerState:
            return [self afterDOCTYPESystemIdentifierState];
        case HTMLBogusDOCTYPETokenizerState:
            return [self bogusDOCTYPEState];
        case HTMLCDATASectionTokenizerState:
            return [self CDATASectionState];
        default:
            NSAssert(NO, @"unexpected state %zd", self.state);
    }
}

- (UTF32Char)consumeNextInputCharacter
{
    return [_inputStream consumeNextInputCharacter];
}

- (NSString *)consumeCharactersUpToFirstPassingTest:(BOOL(^)(UTF32Char c))test
{
    return [_inputStream consumeCharactersUpToFirstPassingTest:test];
}

- (void)switchToState:(HTMLTokenizerState)state
{
    self.state = state;
}

- (void)reconsume:(UTF32Char)character
{
    [_inputStream reconsumeCurrentInputCharacter];
}

- (void)emit:(id)token
{
    if ([token isKindOfClass:[HTMLStartTagToken class]]) {
        _mostRecentEmittedStartTagName = [token tagName];
    }
    if ([token isKindOfClass:[HTMLEndTagToken class]]) {
        HTMLEndTagToken *endTag = token;
        if (endTag.attributes.count > 0 || endTag.selfClosingFlag) {
            [self emitParseError:@"End tag with attributes and/or self-closing flag"];
        }
    }
    [self emitCore:token];
}

- (void)emitCore:(id)token
{
    [_tokenQueue addObject:token];
}

- (void)emitParseError:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2)
{
    va_list args;
    va_start(args, format);
    NSString *error = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self emit:[[HTMLParseErrorToken alloc] initWithError:error]];
}

- (void)emitCharacterToken:(UTF32Char)character
{
    [self emit:[[HTMLCharacterToken alloc] initWithString:StringWithLongCharacter(character)]];
}

- (void)emitCharacterTokenWithString:(NSString *)string
{
    if (string.length > 0) {
        [self emit:[[HTMLCharacterToken alloc] initWithString:string]];
    }
}

- (void)emitCurrentToken
{
    [self emit:_currentToken];
    _currentToken = nil;
}

- (BOOL)currentTagIsAppropriateEndTagToken
{
    HTMLEndTagToken *token = _currentToken;
    return ([token isKindOfClass:[HTMLEndTagToken class]] &&
            [token.tagName isEqualToString:_mostRecentEmittedStartTagName]);
}

- (void)addCurrentAttributeToCurrentToken
{
    HTMLTagToken *token = _currentToken;
    if (token.attributes[_currentAttributeName]) {
        [self emitParseError:@"Duplicate attribute"];
    } else {
        token.attributes[_currentAttributeName] = _currentAttributeValue ?: @"";
    }
    _currentAttributeName = nil;
    _currentAttributeValue = nil;
}

- (NSString *)attemptToConsumeCharacterReference
{
    return [self attemptToConsumeCharacterReferenceIsPartOfAnAttribute:NO];
}

- (NSString *)attemptToConsumeCharacterReferenceAsPartOfAnAttribute
{
    return [self attemptToConsumeCharacterReferenceIsPartOfAnAttribute:YES];
}

- (NSString *)attemptToConsumeCharacterReferenceIsPartOfAnAttribute:(BOOL)partOfAnAttribute
{
    UTF32Char c = _inputStream.nextInputCharacter;
    if (_additionalAllowedCharacter != (UTF32Char)EOF && c == _additionalAllowedCharacter) {
        return nil;
    }
    switch (c) {
        case '\t':
        case '\n':
        case '\f':
        case ' ':
        case '<':
        case '&':
        case EOF:
            return nil;
        case '#': {
            [_inputStream consumeNextInputCharacter];
            BOOL hex = [_inputStream consumeString:@"X" matchingCase:NO];
            unsigned int number;
            BOOL ok;
            if (hex) {
                ok = [_inputStream consumeHexInt:&number];
            } else {
                ok = [_inputStream consumeUnsignedInt:&number];
            }
            if (!ok) {
                [_inputStream unconsumeInputCharacters:(hex ? 2 : 1)];
                [self emitParseError:@"Numeric entity with no numbers"];
                return nil;
            }
            ok = [_inputStream consumeString:@";" matchingCase:YES];
            if (!ok) {
                [self emitParseError:@"Missing semicolon for numeric entity"];
            }
            ReplacementTable *found = Win1252TableLookup(number);
            if (found) {
                [self emitParseError:@"Invalid numeric entity (has replacement)"];
                return [NSString stringWithFormat:@"%C", found->replacement];
            }
            if ((number >= 0xD800 && number <= 0xDFFF) || number > 0x10FFFF) {
                [self emitParseError:@"Invalid numeric entity (outside valid Unicode range)"];
                return @"\uFFFD";
            }
            if (is_undefined_or_disallowed(number)) {
                [self emitParseError:@"Invalid numeric entity (in bad Unicode range)"];
            }
            return StringWithLongCharacter(number);
        }
        default: {
            NSString *substring = [_inputStream nextUnprocessedCharactersWithMaximumLength:LongestReferenceNameLength];
            NamedReferenceTable *longestMatch = LongestNamedReferencePrefix(substring);
            if (!longestMatch) {
                NSScanner *scanner = [_inputStream unprocessedScanner];
                NSCharacterSet *alphanumeric = [NSCharacterSet alphanumericCharacterSet];
                if ([scanner scanCharactersFromSet:alphanumeric intoString:nil] && [scanner scanString:@";" intoString:nil]) {
                    [self emitParseError:@"Unknown named entity with semicolon"];
                }
                return nil;
            }
            [_inputStream consumeString:longestMatch->name matchingCase:YES];
            if (![longestMatch->name hasSuffix:@";"] && partOfAnAttribute) {
                UTF32Char next = _inputStream.nextInputCharacter;
                if (next == '=' || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:next]) {
                    [_inputStream unconsumeInputCharacters:longestMatch->name.length];
                    if (next == '=') {
                        [self emitParseError:@"Named entity in attribute ending with ="];
                    }
                    return nil;
                }
            }
            if (![longestMatch->name hasSuffix:@";"]) {
                [self emitParseError:@"Named entity missing semicolon"];
            }
            return longestMatch->characters;
        }
    }
}

typedef struct {
    unichar number;
    unichar replacement;
} ReplacementTable;

static const ReplacementTable Win1252Table[] = {
    { 0x00, 0xFFFD },
    { 0x0D, 0x000D },
    { 0x80, 0x20AC },
    { 0x81, 0x0081 },
    { 0x82, 0x201A },
    { 0x83, 0x0192 },
    { 0x84, 0x201E },
    { 0x85, 0x2026 },
    { 0x86, 0x2020 },
    { 0x87, 0x2021 },
    { 0x88, 0x02C6 },
    { 0x89, 0x2030 },
    { 0x8A, 0x0160 },
    { 0x8B, 0x2039 },
    { 0x8C, 0x0152 },
    { 0x8D, 0x008D },
    { 0x8E, 0x017D },
    { 0x8F, 0x008F },
    { 0x90, 0x0090 },
    { 0x91, 0x2018 },
    { 0x92, 0x2019 },
    { 0x93, 0x201C },
    { 0x94, 0x201D },
    { 0x95, 0x2022 },
    { 0x96, 0x2013 },
    { 0x97, 0x2014 },
    { 0x98, 0x02DC },
    { 0x99, 0x2122 },
    { 0x9A, 0x0161 },
    { 0x9B, 0x203A },
    { 0x9C, 0x0153 },
    { 0x9D, 0x009D },
    { 0x9E, 0x017E },
    { 0x9F, 0x0178 },
};

static inline ReplacementTable * Win1252TableLookup(unsigned int number)
{
    static int (^comparator)() = ^(const void *voidKey, const void *voidItem) {
        const unsigned int *key = voidKey;
        const ReplacementTable *item = voidItem;
        if (item->number < *key) {
            return 1;
        } else if (*key < item->number) {
            return -1;
        } else {
            return 0;
        }
    };
    return bsearch_b(&number, Win1252Table, sizeof(Win1252Table) / sizeof(Win1252Table[0]), sizeof(ReplacementTable), comparator);
}

typedef struct {
    __unsafe_unretained NSString *name;
    __unsafe_unretained NSString *characters;
} NamedReferenceTable;

static const NamedReferenceTable NamedReferences[] = {
    { @"AElig;", @"\U000000c6" },
    { @"AMP;", @"&" },
    { @"Aacute;", @"\U000000c1" },
    { @"Abreve;", @"\U00000102" },
    { @"Acirc;", @"\U000000c2" },
    { @"Acy;", @"\U00000410" },
    { @"Afr;", @"\U0001d504" },
    { @"Agrave;", @"\U000000c0" },
    { @"Alpha;", @"\U00000391" },
    { @"Amacr;", @"\U00000100" },
    { @"And;", @"\U00002a53" },
    { @"Aogon;", @"\U00000104" },
    { @"Aopf;", @"\U0001d538" },
    { @"ApplyFunction;", @"\U00002061" },
    { @"Aring;", @"\U000000c5" },
    { @"Ascr;", @"\U0001d49c" },
    { @"Assign;", @"\U00002254" },
    { @"Atilde;", @"\U000000c3" },
    { @"Auml;", @"\U000000c4" },
    { @"Backslash;", @"\U00002216" },
    { @"Barv;", @"\U00002ae7" },
    { @"Barwed;", @"\U00002306" },
    { @"Bcy;", @"\U00000411" },
    { @"Because;", @"\U00002235" },
    { @"Bernoullis;", @"\U0000212c" },
    { @"Beta;", @"\U00000392" },
    { @"Bfr;", @"\U0001d505" },
    { @"Bopf;", @"\U0001d539" },
    { @"Breve;", @"\U000002d8" },
    { @"Bscr;", @"\U0000212c" },
    { @"Bumpeq;", @"\U0000224e" },
    { @"CHcy;", @"\U00000427" },
    { @"COPY;", @"\U000000a9" },
    { @"Cacute;", @"\U00000106" },
    { @"Cap;", @"\U000022d2" },
    { @"CapitalDifferentialD;", @"\U00002145" },
    { @"Cayleys;", @"\U0000212d" },
    { @"Ccaron;", @"\U0000010c" },
    { @"Ccedil;", @"\U000000c7" },
    { @"Ccirc;", @"\U00000108" },
    { @"Cconint;", @"\U00002230" },
    { @"Cdot;", @"\U0000010a" },
    { @"Cedilla;", @"\U000000b8" },
    { @"CenterDot;", @"\U000000b7" },
    { @"Cfr;", @"\U0000212d" },
    { @"Chi;", @"\U000003a7" },
    { @"CircleDot;", @"\U00002299" },
    { @"CircleMinus;", @"\U00002296" },
    { @"CirclePlus;", @"\U00002295" },
    { @"CircleTimes;", @"\U00002297" },
    { @"ClockwiseContourIntegral;", @"\U00002232" },
    { @"CloseCurlyDoubleQuote;", @"\U0000201d" },
    { @"CloseCurlyQuote;", @"\U00002019" },
    { @"Colon;", @"\U00002237" },
    { @"Colone;", @"\U00002a74" },
    { @"Congruent;", @"\U00002261" },
    { @"Conint;", @"\U0000222f" },
    { @"ContourIntegral;", @"\U0000222e" },
    { @"Copf;", @"\U00002102" },
    { @"Coproduct;", @"\U00002210" },
    { @"CounterClockwiseContourIntegral;", @"\U00002233" },
    { @"Cross;", @"\U00002a2f" },
    { @"Cscr;", @"\U0001d49e" },
    { @"Cup;", @"\U000022d3" },
    { @"CupCap;", @"\U0000224d" },
    { @"DD;", @"\U00002145" },
    { @"DDotrahd;", @"\U00002911" },
    { @"DJcy;", @"\U00000402" },
    { @"DScy;", @"\U00000405" },
    { @"DZcy;", @"\U0000040f" },
    { @"Dagger;", @"\U00002021" },
    { @"Darr;", @"\U000021a1" },
    { @"Dashv;", @"\U00002ae4" },
    { @"Dcaron;", @"\U0000010e" },
    { @"Dcy;", @"\U00000414" },
    { @"Del;", @"\U00002207" },
    { @"Delta;", @"\U00000394" },
    { @"Dfr;", @"\U0001d507" },
    { @"DiacriticalAcute;", @"\U000000b4" },
    { @"DiacriticalDot;", @"\U000002d9" },
    { @"DiacriticalDoubleAcute;", @"\U000002dd" },
    { @"DiacriticalGrave;", @"\U00000060" },
    { @"DiacriticalTilde;", @"\U000002dc" },
    { @"Diamond;", @"\U000022c4" },
    { @"DifferentialD;", @"\U00002146" },
    { @"Dopf;", @"\U0001d53b" },
    { @"Dot;", @"\U000000a8" },
    { @"DotDot;", @"\U000020dc" },
    { @"DotEqual;", @"\U00002250" },
    { @"DoubleContourIntegral;", @"\U0000222f" },
    { @"DoubleDot;", @"\U000000a8" },
    { @"DoubleDownArrow;", @"\U000021d3" },
    { @"DoubleLeftArrow;", @"\U000021d0" },
    { @"DoubleLeftRightArrow;", @"\U000021d4" },
    { @"DoubleLeftTee;", @"\U00002ae4" },
    { @"DoubleLongLeftArrow;", @"\U000027f8" },
    { @"DoubleLongLeftRightArrow;", @"\U000027fa" },
    { @"DoubleLongRightArrow;", @"\U000027f9" },
    { @"DoubleRightArrow;", @"\U000021d2" },
    { @"DoubleRightTee;", @"\U000022a8" },
    { @"DoubleUpArrow;", @"\U000021d1" },
    { @"DoubleUpDownArrow;", @"\U000021d5" },
    { @"DoubleVerticalBar;", @"\U00002225" },
    { @"DownArrow;", @"\U00002193" },
    { @"DownArrowBar;", @"\U00002913" },
    { @"DownArrowUpArrow;", @"\U000021f5" },
    { @"DownBreve;", @"\U00000311" },
    { @"DownLeftRightVector;", @"\U00002950" },
    { @"DownLeftTeeVector;", @"\U0000295e" },
    { @"DownLeftVector;", @"\U000021bd" },
    { @"DownLeftVectorBar;", @"\U00002956" },
    { @"DownRightTeeVector;", @"\U0000295f" },
    { @"DownRightVector;", @"\U000021c1" },
    { @"DownRightVectorBar;", @"\U00002957" },
    { @"DownTee;", @"\U000022a4" },
    { @"DownTeeArrow;", @"\U000021a7" },
    { @"Downarrow;", @"\U000021d3" },
    { @"Dscr;", @"\U0001d49f" },
    { @"Dstrok;", @"\U00000110" },
    { @"ENG;", @"\U0000014a" },
    { @"ETH;", @"\U000000d0" },
    { @"Eacute;", @"\U000000c9" },
    { @"Ecaron;", @"\U0000011a" },
    { @"Ecirc;", @"\U000000ca" },
    { @"Ecy;", @"\U0000042d" },
    { @"Edot;", @"\U00000116" },
    { @"Efr;", @"\U0001d508" },
    { @"Egrave;", @"\U000000c8" },
    { @"Element;", @"\U00002208" },
    { @"Emacr;", @"\U00000112" },
    { @"EmptySmallSquare;", @"\U000025fb" },
    { @"EmptyVerySmallSquare;", @"\U000025ab" },
    { @"Eogon;", @"\U00000118" },
    { @"Eopf;", @"\U0001d53c" },
    { @"Epsilon;", @"\U00000395" },
    { @"Equal;", @"\U00002a75" },
    { @"EqualTilde;", @"\U00002242" },
    { @"Equilibrium;", @"\U000021cc" },
    { @"Escr;", @"\U00002130" },
    { @"Esim;", @"\U00002a73" },
    { @"Eta;", @"\U00000397" },
    { @"Euml;", @"\U000000cb" },
    { @"Exists;", @"\U00002203" },
    { @"ExponentialE;", @"\U00002147" },
    { @"Fcy;", @"\U00000424" },
    { @"Ffr;", @"\U0001d509" },
    { @"FilledSmallSquare;", @"\U000025fc" },
    { @"FilledVerySmallSquare;", @"\U000025aa" },
    { @"Fopf;", @"\U0001d53d" },
    { @"ForAll;", @"\U00002200" },
    { @"Fouriertrf;", @"\U00002131" },
    { @"Fscr;", @"\U00002131" },
    { @"GJcy;", @"\U00000403" },
    { @"GT;", @">" },
    { @"Gamma;", @"\U00000393" },
    { @"Gammad;", @"\U000003dc" },
    { @"Gbreve;", @"\U0000011e" },
    { @"Gcedil;", @"\U00000122" },
    { @"Gcirc;", @"\U0000011c" },
    { @"Gcy;", @"\U00000413" },
    { @"Gdot;", @"\U00000120" },
    { @"Gfr;", @"\U0001d50a" },
    { @"Gg;", @"\U000022d9" },
    { @"Gopf;", @"\U0001d53e" },
    { @"GreaterEqual;", @"\U00002265" },
    { @"GreaterEqualLess;", @"\U000022db" },
    { @"GreaterFullEqual;", @"\U00002267" },
    { @"GreaterGreater;", @"\U00002aa2" },
    { @"GreaterLess;", @"\U00002277" },
    { @"GreaterSlantEqual;", @"\U00002a7e" },
    { @"GreaterTilde;", @"\U00002273" },
    { @"Gscr;", @"\U0001d4a2" },
    { @"Gt;", @"\U0000226b" },
    { @"HARDcy;", @"\U0000042a" },
    { @"Hacek;", @"\U000002c7" },
    { @"Hat;", @"^" },
    { @"Hcirc;", @"\U00000124" },
    { @"Hfr;", @"\U0000210c" },
    { @"HilbertSpace;", @"\U0000210b" },
    { @"Hopf;", @"\U0000210d" },
    { @"HorizontalLine;", @"\U00002500" },
    { @"Hscr;", @"\U0000210b" },
    { @"Hstrok;", @"\U00000126" },
    { @"HumpDownHump;", @"\U0000224e" },
    { @"HumpEqual;", @"\U0000224f" },
    { @"IEcy;", @"\U00000415" },
    { @"IJlig;", @"\U00000132" },
    { @"IOcy;", @"\U00000401" },
    { @"Iacute;", @"\U000000cd" },
    { @"Icirc;", @"\U000000ce" },
    { @"Icy;", @"\U00000418" },
    { @"Idot;", @"\U00000130" },
    { @"Ifr;", @"\U00002111" },
    { @"Igrave;", @"\U000000cc" },
    { @"Im;", @"\U00002111" },
    { @"Imacr;", @"\U0000012a" },
    { @"ImaginaryI;", @"\U00002148" },
    { @"Implies;", @"\U000021d2" },
    { @"Int;", @"\U0000222c" },
    { @"Integral;", @"\U0000222b" },
    { @"Intersection;", @"\U000022c2" },
    { @"InvisibleComma;", @"\U00002063" },
    { @"InvisibleTimes;", @"\U00002062" },
    { @"Iogon;", @"\U0000012e" },
    { @"Iopf;", @"\U0001d540" },
    { @"Iota;", @"\U00000399" },
    { @"Iscr;", @"\U00002110" },
    { @"Itilde;", @"\U00000128" },
    { @"Iukcy;", @"\U00000406" },
    { @"Iuml;", @"\U000000cf" },
    { @"Jcirc;", @"\U00000134" },
    { @"Jcy;", @"\U00000419" },
    { @"Jfr;", @"\U0001d50d" },
    { @"Jopf;", @"\U0001d541" },
    { @"Jscr;", @"\U0001d4a5" },
    { @"Jsercy;", @"\U00000408" },
    { @"Jukcy;", @"\U00000404" },
    { @"KHcy;", @"\U00000425" },
    { @"KJcy;", @"\U0000040c" },
    { @"Kappa;", @"\U0000039a" },
    { @"Kcedil;", @"\U00000136" },
    { @"Kcy;", @"\U0000041a" },
    { @"Kfr;", @"\U0001d50e" },
    { @"Kopf;", @"\U0001d542" },
    { @"Kscr;", @"\U0001d4a6" },
    { @"LJcy;", @"\U00000409" },
    { @"LT;", @"<" },
    { @"Lacute;", @"\U00000139" },
    { @"Lambda;", @"\U0000039b" },
    { @"Lang;", @"\U000027ea" },
    { @"Laplacetrf;", @"\U00002112" },
    { @"Larr;", @"\U0000219e" },
    { @"Lcaron;", @"\U0000013d" },
    { @"Lcedil;", @"\U0000013b" },
    { @"Lcy;", @"\U0000041b" },
    { @"LeftAngleBracket;", @"\U000027e8" },
    { @"LeftArrow;", @"\U00002190" },
    { @"LeftArrowBar;", @"\U000021e4" },
    { @"LeftArrowRightArrow;", @"\U000021c6" },
    { @"LeftCeiling;", @"\U00002308" },
    { @"LeftDoubleBracket;", @"\U000027e6" },
    { @"LeftDownTeeVector;", @"\U00002961" },
    { @"LeftDownVector;", @"\U000021c3" },
    { @"LeftDownVectorBar;", @"\U00002959" },
    { @"LeftFloor;", @"\U0000230a" },
    { @"LeftRightArrow;", @"\U00002194" },
    { @"LeftRightVector;", @"\U0000294e" },
    { @"LeftTee;", @"\U000022a3" },
    { @"LeftTeeArrow;", @"\U000021a4" },
    { @"LeftTeeVector;", @"\U0000295a" },
    { @"LeftTriangle;", @"\U000022b2" },
    { @"LeftTriangleBar;", @"\U000029cf" },
    { @"LeftTriangleEqual;", @"\U000022b4" },
    { @"LeftUpDownVector;", @"\U00002951" },
    { @"LeftUpTeeVector;", @"\U00002960" },
    { @"LeftUpVector;", @"\U000021bf" },
    { @"LeftUpVectorBar;", @"\U00002958" },
    { @"LeftVector;", @"\U000021bc" },
    { @"LeftVectorBar;", @"\U00002952" },
    { @"Leftarrow;", @"\U000021d0" },
    { @"Leftrightarrow;", @"\U000021d4" },
    { @"LessEqualGreater;", @"\U000022da" },
    { @"LessFullEqual;", @"\U00002266" },
    { @"LessGreater;", @"\U00002276" },
    { @"LessLess;", @"\U00002aa1" },
    { @"LessSlantEqual;", @"\U00002a7d" },
    { @"LessTilde;", @"\U00002272" },
    { @"Lfr;", @"\U0001d50f" },
    { @"Ll;", @"\U000022d8" },
    { @"Lleftarrow;", @"\U000021da" },
    { @"Lmidot;", @"\U0000013f" },
    { @"LongLeftArrow;", @"\U000027f5" },
    { @"LongLeftRightArrow;", @"\U000027f7" },
    { @"LongRightArrow;", @"\U000027f6" },
    { @"Longleftarrow;", @"\U000027f8" },
    { @"Longleftrightarrow;", @"\U000027fa" },
    { @"Longrightarrow;", @"\U000027f9" },
    { @"Lopf;", @"\U0001d543" },
    { @"LowerLeftArrow;", @"\U00002199" },
    { @"LowerRightArrow;", @"\U00002198" },
    { @"Lscr;", @"\U00002112" },
    { @"Lsh;", @"\U000021b0" },
    { @"Lstrok;", @"\U00000141" },
    { @"Lt;", @"\U0000226a" },
    { @"Map;", @"\U00002905" },
    { @"Mcy;", @"\U0000041c" },
    { @"MediumSpace;", @"\U0000205f" },
    { @"Mellintrf;", @"\U00002133" },
    { @"Mfr;", @"\U0001d510" },
    { @"MinusPlus;", @"\U00002213" },
    { @"Mopf;", @"\U0001d544" },
    { @"Mscr;", @"\U00002133" },
    { @"Mu;", @"\U0000039c" },
    { @"NJcy;", @"\U0000040a" },
    { @"Nacute;", @"\U00000143" },
    { @"Ncaron;", @"\U00000147" },
    { @"Ncedil;", @"\U00000145" },
    { @"Ncy;", @"\U0000041d" },
    { @"NegativeMediumSpace;", @"\U0000200b" },
    { @"NegativeThickSpace;", @"\U0000200b" },
    { @"NegativeThinSpace;", @"\U0000200b" },
    { @"NegativeVeryThinSpace;", @"\U0000200b" },
    { @"NestedGreaterGreater;", @"\U0000226b" },
    { @"NestedLessLess;", @"\U0000226a" },
    { @"NewLine;", @"\n" },
    { @"Nfr;", @"\U0001d511" },
    { @"NoBreak;", @"\U00002060" },
    { @"NonBreakingSpace;", @"\U000000a0" },
    { @"Nopf;", @"\U00002115" },
    { @"Not;", @"\U00002aec" },
    { @"NotCongruent;", @"\U00002262" },
    { @"NotCupCap;", @"\U0000226d" },
    { @"NotDoubleVerticalBar;", @"\U00002226" },
    { @"NotElement;", @"\U00002209" },
    { @"NotEqual;", @"\U00002260" },
    { @"NotEqualTilde;", @"\U00002242\U00000338" },
    { @"NotExists;", @"\U00002204" },
    { @"NotGreater;", @"\U0000226f" },
    { @"NotGreaterEqual;", @"\U00002271" },
    { @"NotGreaterFullEqual;", @"\U00002267\U00000338" },
    { @"NotGreaterGreater;", @"\U0000226b\U00000338" },
    { @"NotGreaterLess;", @"\U00002279" },
    { @"NotGreaterSlantEqual;", @"\U00002a7e\U00000338" },
    { @"NotGreaterTilde;", @"\U00002275" },
    { @"NotHumpDownHump;", @"\U0000224e\U00000338" },
    { @"NotHumpEqual;", @"\U0000224f\U00000338" },
    { @"NotLeftTriangle;", @"\U000022ea" },
    { @"NotLeftTriangleBar;", @"\U000029cf\U00000338" },
    { @"NotLeftTriangleEqual;", @"\U000022ec" },
    { @"NotLess;", @"\U0000226e" },
    { @"NotLessEqual;", @"\U00002270" },
    { @"NotLessGreater;", @"\U00002278" },
    { @"NotLessLess;", @"\U0000226a\U00000338" },
    { @"NotLessSlantEqual;", @"\U00002a7d\U00000338" },
    { @"NotLessTilde;", @"\U00002274" },
    { @"NotNestedGreaterGreater;", @"\U00002aa2\U00000338" },
    { @"NotNestedLessLess;", @"\U00002aa1\U00000338" },
    { @"NotPrecedes;", @"\U00002280" },
    { @"NotPrecedesEqual;", @"\U00002aaf\U00000338" },
    { @"NotPrecedesSlantEqual;", @"\U000022e0" },
    { @"NotReverseElement;", @"\U0000220c" },
    { @"NotRightTriangle;", @"\U000022eb" },
    { @"NotRightTriangleBar;", @"\U000029d0\U00000338" },
    { @"NotRightTriangleEqual;", @"\U000022ed" },
    { @"NotSquareSubset;", @"\U0000228f\U00000338" },
    { @"NotSquareSubsetEqual;", @"\U000022e2" },
    { @"NotSquareSuperset;", @"\U00002290\U00000338" },
    { @"NotSquareSupersetEqual;", @"\U000022e3" },
    { @"NotSubset;", @"\U00002282\U000020d2" },
    { @"NotSubsetEqual;", @"\U00002288" },
    { @"NotSucceeds;", @"\U00002281" },
    { @"NotSucceedsEqual;", @"\U00002ab0\U00000338" },
    { @"NotSucceedsSlantEqual;", @"\U000022e1" },
    { @"NotSucceedsTilde;", @"\U0000227f\U00000338" },
    { @"NotSuperset;", @"\U00002283\U000020d2" },
    { @"NotSupersetEqual;", @"\U00002289" },
    { @"NotTilde;", @"\U00002241" },
    { @"NotTildeEqual;", @"\U00002244" },
    { @"NotTildeFullEqual;", @"\U00002247" },
    { @"NotTildeTilde;", @"\U00002249" },
    { @"NotVerticalBar;", @"\U00002224" },
    { @"Nscr;", @"\U0001d4a9" },
    { @"Ntilde;", @"\U000000d1" },
    { @"Nu;", @"\U0000039d" },
    { @"OElig;", @"\U00000152" },
    { @"Oacute;", @"\U000000d3" },
    { @"Ocirc;", @"\U000000d4" },
    { @"Ocy;", @"\U0000041e" },
    { @"Odblac;", @"\U00000150" },
    { @"Ofr;", @"\U0001d512" },
    { @"Ograve;", @"\U000000d2" },
    { @"Omacr;", @"\U0000014c" },
    { @"Omega;", @"\U000003a9" },
    { @"Omicron;", @"\U0000039f" },
    { @"Oopf;", @"\U0001d546" },
    { @"OpenCurlyDoubleQuote;", @"\U0000201c" },
    { @"OpenCurlyQuote;", @"\U00002018" },
    { @"Or;", @"\U00002a54" },
    { @"Oscr;", @"\U0001d4aa" },
    { @"Oslash;", @"\U000000d8" },
    { @"Otilde;", @"\U000000d5" },
    { @"Otimes;", @"\U00002a37" },
    { @"Ouml;", @"\U000000d6" },
    { @"OverBar;", @"\U0000203e" },
    { @"OverBrace;", @"\U000023de" },
    { @"OverBracket;", @"\U000023b4" },
    { @"OverParenthesis;", @"\U000023dc" },
    { @"PartialD;", @"\U00002202" },
    { @"Pcy;", @"\U0000041f" },
    { @"Pfr;", @"\U0001d513" },
    { @"Phi;", @"\U000003a6" },
    { @"Pi;", @"\U000003a0" },
    { @"PlusMinus;", @"\U000000b1" },
    { @"Poincareplane;", @"\U0000210c" },
    { @"Popf;", @"\U00002119" },
    { @"Pr;", @"\U00002abb" },
    { @"Precedes;", @"\U0000227a" },
    { @"PrecedesEqual;", @"\U00002aaf" },
    { @"PrecedesSlantEqual;", @"\U0000227c" },
    { @"PrecedesTilde;", @"\U0000227e" },
    { @"Prime;", @"\U00002033" },
    { @"Product;", @"\U0000220f" },
    { @"Proportion;", @"\U00002237" },
    { @"Proportional;", @"\U0000221d" },
    { @"Pscr;", @"\U0001d4ab" },
    { @"Psi;", @"\U000003a8" },
    { @"QUOT;", @"\"" },
    { @"Qfr;", @"\U0001d514" },
    { @"Qopf;", @"\U0000211a" },
    { @"Qscr;", @"\U0001d4ac" },
    { @"RBarr;", @"\U00002910" },
    { @"REG;", @"\U000000ae" },
    { @"Racute;", @"\U00000154" },
    { @"Rang;", @"\U000027eb" },
    { @"Rarr;", @"\U000021a0" },
    { @"Rarrtl;", @"\U00002916" },
    { @"Rcaron;", @"\U00000158" },
    { @"Rcedil;", @"\U00000156" },
    { @"Rcy;", @"\U00000420" },
    { @"Re;", @"\U0000211c" },
    { @"ReverseElement;", @"\U0000220b" },
    { @"ReverseEquilibrium;", @"\U000021cb" },
    { @"ReverseUpEquilibrium;", @"\U0000296f" },
    { @"Rfr;", @"\U0000211c" },
    { @"Rho;", @"\U000003a1" },
    { @"RightAngleBracket;", @"\U000027e9" },
    { @"RightArrow;", @"\U00002192" },
    { @"RightArrowBar;", @"\U000021e5" },
    { @"RightArrowLeftArrow;", @"\U000021c4" },
    { @"RightCeiling;", @"\U00002309" },
    { @"RightDoubleBracket;", @"\U000027e7" },
    { @"RightDownTeeVector;", @"\U0000295d" },
    { @"RightDownVector;", @"\U000021c2" },
    { @"RightDownVectorBar;", @"\U00002955" },
    { @"RightFloor;", @"\U0000230b" },
    { @"RightTee;", @"\U000022a2" },
    { @"RightTeeArrow;", @"\U000021a6" },
    { @"RightTeeVector;", @"\U0000295b" },
    { @"RightTriangle;", @"\U000022b3" },
    { @"RightTriangleBar;", @"\U000029d0" },
    { @"RightTriangleEqual;", @"\U000022b5" },
    { @"RightUpDownVector;", @"\U0000294f" },
    { @"RightUpTeeVector;", @"\U0000295c" },
    { @"RightUpVector;", @"\U000021be" },
    { @"RightUpVectorBar;", @"\U00002954" },
    { @"RightVector;", @"\U000021c0" },
    { @"RightVectorBar;", @"\U00002953" },
    { @"Rightarrow;", @"\U000021d2" },
    { @"Ropf;", @"\U0000211d" },
    { @"RoundImplies;", @"\U00002970" },
    { @"Rrightarrow;", @"\U000021db" },
    { @"Rscr;", @"\U0000211b" },
    { @"Rsh;", @"\U000021b1" },
    { @"RuleDelayed;", @"\U000029f4" },
    { @"SHCHcy;", @"\U00000429" },
    { @"SHcy;", @"\U00000428" },
    { @"SOFTcy;", @"\U0000042c" },
    { @"Sacute;", @"\U0000015a" },
    { @"Sc;", @"\U00002abc" },
    { @"Scaron;", @"\U00000160" },
    { @"Scedil;", @"\U0000015e" },
    { @"Scirc;", @"\U0000015c" },
    { @"Scy;", @"\U00000421" },
    { @"Sfr;", @"\U0001d516" },
    { @"ShortDownArrow;", @"\U00002193" },
    { @"ShortLeftArrow;", @"\U00002190" },
    { @"ShortRightArrow;", @"\U00002192" },
    { @"ShortUpArrow;", @"\U00002191" },
    { @"Sigma;", @"\U000003a3" },
    { @"SmallCircle;", @"\U00002218" },
    { @"Sopf;", @"\U0001d54a" },
    { @"Sqrt;", @"\U0000221a" },
    { @"Square;", @"\U000025a1" },
    { @"SquareIntersection;", @"\U00002293" },
    { @"SquareSubset;", @"\U0000228f" },
    { @"SquareSubsetEqual;", @"\U00002291" },
    { @"SquareSuperset;", @"\U00002290" },
    { @"SquareSupersetEqual;", @"\U00002292" },
    { @"SquareUnion;", @"\U00002294" },
    { @"Sscr;", @"\U0001d4ae" },
    { @"Star;", @"\U000022c6" },
    { @"Sub;", @"\U000022d0" },
    { @"Subset;", @"\U000022d0" },
    { @"SubsetEqual;", @"\U00002286" },
    { @"Succeeds;", @"\U0000227b" },
    { @"SucceedsEqual;", @"\U00002ab0" },
    { @"SucceedsSlantEqual;", @"\U0000227d" },
    { @"SucceedsTilde;", @"\U0000227f" },
    { @"SuchThat;", @"\U0000220b" },
    { @"Sum;", @"\U00002211" },
    { @"Sup;", @"\U000022d1" },
    { @"Superset;", @"\U00002283" },
    { @"SupersetEqual;", @"\U00002287" },
    { @"Supset;", @"\U000022d1" },
    { @"THORN;", @"\U000000de" },
    { @"TRADE;", @"\U00002122" },
    { @"TSHcy;", @"\U0000040b" },
    { @"TScy;", @"\U00000426" },
    { @"Tab;", @"\t" },
    { @"Tau;", @"\U000003a4" },
    { @"Tcaron;", @"\U00000164" },
    { @"Tcedil;", @"\U00000162" },
    { @"Tcy;", @"\U00000422" },
    { @"Tfr;", @"\U0001d517" },
    { @"Therefore;", @"\U00002234" },
    { @"Theta;", @"\U00000398" },
    { @"ThickSpace;", @"\U0000205f\U0000200a" },
    { @"ThinSpace;", @"\U00002009" },
    { @"Tilde;", @"\U0000223c" },
    { @"TildeEqual;", @"\U00002243" },
    { @"TildeFullEqual;", @"\U00002245" },
    { @"TildeTilde;", @"\U00002248" },
    { @"Topf;", @"\U0001d54b" },
    { @"TripleDot;", @"\U000020db" },
    { @"Tscr;", @"\U0001d4af" },
    { @"Tstrok;", @"\U00000166" },
    { @"Uacute;", @"\U000000da" },
    { @"Uarr;", @"\U0000219f" },
    { @"Uarrocir;", @"\U00002949" },
    { @"Ubrcy;", @"\U0000040e" },
    { @"Ubreve;", @"\U0000016c" },
    { @"Ucirc;", @"\U000000db" },
    { @"Ucy;", @"\U00000423" },
    { @"Udblac;", @"\U00000170" },
    { @"Ufr;", @"\U0001d518" },
    { @"Ugrave;", @"\U000000d9" },
    { @"Umacr;", @"\U0000016a" },
    { @"UnderBar;", @"_" },
    { @"UnderBrace;", @"\U000023df" },
    { @"UnderBracket;", @"\U000023b5" },
    { @"UnderParenthesis;", @"\U000023dd" },
    { @"Union;", @"\U000022c3" },
    { @"UnionPlus;", @"\U0000228e" },
    { @"Uogon;", @"\U00000172" },
    { @"Uopf;", @"\U0001d54c" },
    { @"UpArrow;", @"\U00002191" },
    { @"UpArrowBar;", @"\U00002912" },
    { @"UpArrowDownArrow;", @"\U000021c5" },
    { @"UpDownArrow;", @"\U00002195" },
    { @"UpEquilibrium;", @"\U0000296e" },
    { @"UpTee;", @"\U000022a5" },
    { @"UpTeeArrow;", @"\U000021a5" },
    { @"Uparrow;", @"\U000021d1" },
    { @"Updownarrow;", @"\U000021d5" },
    { @"UpperLeftArrow;", @"\U00002196" },
    { @"UpperRightArrow;", @"\U00002197" },
    { @"Upsi;", @"\U000003d2" },
    { @"Upsilon;", @"\U000003a5" },
    { @"Uring;", @"\U0000016e" },
    { @"Uscr;", @"\U0001d4b0" },
    { @"Utilde;", @"\U00000168" },
    { @"Uuml;", @"\U000000dc" },
    { @"VDash;", @"\U000022ab" },
    { @"Vbar;", @"\U00002aeb" },
    { @"Vcy;", @"\U00000412" },
    { @"Vdash;", @"\U000022a9" },
    { @"Vdashl;", @"\U00002ae6" },
    { @"Vee;", @"\U000022c1" },
    { @"Verbar;", @"\U00002016" },
    { @"Vert;", @"\U00002016" },
    { @"VerticalBar;", @"\U00002223" },
    { @"VerticalLine;", @"|" },
    { @"VerticalSeparator;", @"\U00002758" },
    { @"VerticalTilde;", @"\U00002240" },
    { @"VeryThinSpace;", @"\U0000200a" },
    { @"Vfr;", @"\U0001d519" },
    { @"Vopf;", @"\U0001d54d" },
    { @"Vscr;", @"\U0001d4b1" },
    { @"Vvdash;", @"\U000022aa" },
    { @"Wcirc;", @"\U00000174" },
    { @"Wedge;", @"\U000022c0" },
    { @"Wfr;", @"\U0001d51a" },
    { @"Wopf;", @"\U0001d54e" },
    { @"Wscr;", @"\U0001d4b2" },
    { @"Xfr;", @"\U0001d51b" },
    { @"Xi;", @"\U0000039e" },
    { @"Xopf;", @"\U0001d54f" },
    { @"Xscr;", @"\U0001d4b3" },
    { @"YAcy;", @"\U0000042f" },
    { @"YIcy;", @"\U00000407" },
    { @"YUcy;", @"\U0000042e" },
    { @"Yacute;", @"\U000000dd" },
    { @"Ycirc;", @"\U00000176" },
    { @"Ycy;", @"\U0000042b" },
    { @"Yfr;", @"\U0001d51c" },
    { @"Yopf;", @"\U0001d550" },
    { @"Yscr;", @"\U0001d4b4" },
    { @"Yuml;", @"\U00000178" },
    { @"ZHcy;", @"\U00000416" },
    { @"Zacute;", @"\U00000179" },
    { @"Zcaron;", @"\U0000017d" },
    { @"Zcy;", @"\U00000417" },
    { @"Zdot;", @"\U0000017b" },
    { @"ZeroWidthSpace;", @"\U0000200b" },
    { @"Zeta;", @"\U00000396" },
    { @"Zfr;", @"\U00002128" },
    { @"Zopf;", @"\U00002124" },
    { @"Zscr;", @"\U0001d4b5" },
    { @"aacute;", @"\U000000e1" },
    { @"abreve;", @"\U00000103" },
    { @"ac;", @"\U0000223e" },
    { @"acE;", @"\U0000223e\U00000333" },
    { @"acd;", @"\U0000223f" },
    { @"acirc;", @"\U000000e2" },
    { @"acute;", @"\U000000b4" },
    { @"acy;", @"\U00000430" },
    { @"aelig;", @"\U000000e6" },
    { @"af;", @"\U00002061" },
    { @"afr;", @"\U0001d51e" },
    { @"agrave;", @"\U000000e0" },
    { @"alefsym;", @"\U00002135" },
    { @"aleph;", @"\U00002135" },
    { @"alpha;", @"\U000003b1" },
    { @"amacr;", @"\U00000101" },
    { @"amalg;", @"\U00002a3f" },
    { @"amp;", @"&" },
    { @"and;", @"\U00002227" },
    { @"andand;", @"\U00002a55" },
    { @"andd;", @"\U00002a5c" },
    { @"andslope;", @"\U00002a58" },
    { @"andv;", @"\U00002a5a" },
    { @"ang;", @"\U00002220" },
    { @"ange;", @"\U000029a4" },
    { @"angle;", @"\U00002220" },
    { @"angmsd;", @"\U00002221" },
    { @"angmsdaa;", @"\U000029a8" },
    { @"angmsdab;", @"\U000029a9" },
    { @"angmsdac;", @"\U000029aa" },
    { @"angmsdad;", @"\U000029ab" },
    { @"angmsdae;", @"\U000029ac" },
    { @"angmsdaf;", @"\U000029ad" },
    { @"angmsdag;", @"\U000029ae" },
    { @"angmsdah;", @"\U000029af" },
    { @"angrt;", @"\U0000221f" },
    { @"angrtvb;", @"\U000022be" },
    { @"angrtvbd;", @"\U0000299d" },
    { @"angsph;", @"\U00002222" },
    { @"angst;", @"\U000000c5" },
    { @"angzarr;", @"\U0000237c" },
    { @"aogon;", @"\U00000105" },
    { @"aopf;", @"\U0001d552" },
    { @"ap;", @"\U00002248" },
    { @"apE;", @"\U00002a70" },
    { @"apacir;", @"\U00002a6f" },
    { @"ape;", @"\U0000224a" },
    { @"apid;", @"\U0000224b" },
    { @"apos;", @"'" },
    { @"approx;", @"\U00002248" },
    { @"approxeq;", @"\U0000224a" },
    { @"aring;", @"\U000000e5" },
    { @"ascr;", @"\U0001d4b6" },
    { @"ast;", @"*" },
    { @"asymp;", @"\U00002248" },
    { @"asympeq;", @"\U0000224d" },
    { @"atilde;", @"\U000000e3" },
    { @"auml;", @"\U000000e4" },
    { @"awconint;", @"\U00002233" },
    { @"awint;", @"\U00002a11" },
    { @"bNot;", @"\U00002aed" },
    { @"backcong;", @"\U0000224c" },
    { @"backepsilon;", @"\U000003f6" },
    { @"backprime;", @"\U00002035" },
    { @"backsim;", @"\U0000223d" },
    { @"backsimeq;", @"\U000022cd" },
    { @"barvee;", @"\U000022bd" },
    { @"barwed;", @"\U00002305" },
    { @"barwedge;", @"\U00002305" },
    { @"bbrk;", @"\U000023b5" },
    { @"bbrktbrk;", @"\U000023b6" },
    { @"bcong;", @"\U0000224c" },
    { @"bcy;", @"\U00000431" },
    { @"bdquo;", @"\U0000201e" },
    { @"becaus;", @"\U00002235" },
    { @"because;", @"\U00002235" },
    { @"bemptyv;", @"\U000029b0" },
    { @"bepsi;", @"\U000003f6" },
    { @"bernou;", @"\U0000212c" },
    { @"beta;", @"\U000003b2" },
    { @"beth;", @"\U00002136" },
    { @"between;", @"\U0000226c" },
    { @"bfr;", @"\U0001d51f" },
    { @"bigcap;", @"\U000022c2" },
    { @"bigcirc;", @"\U000025ef" },
    { @"bigcup;", @"\U000022c3" },
    { @"bigodot;", @"\U00002a00" },
    { @"bigoplus;", @"\U00002a01" },
    { @"bigotimes;", @"\U00002a02" },
    { @"bigsqcup;", @"\U00002a06" },
    { @"bigstar;", @"\U00002605" },
    { @"bigtriangledown;", @"\U000025bd" },
    { @"bigtriangleup;", @"\U000025b3" },
    { @"biguplus;", @"\U00002a04" },
    { @"bigvee;", @"\U000022c1" },
    { @"bigwedge;", @"\U000022c0" },
    { @"bkarow;", @"\U0000290d" },
    { @"blacklozenge;", @"\U000029eb" },
    { @"blacksquare;", @"\U000025aa" },
    { @"blacktriangle;", @"\U000025b4" },
    { @"blacktriangledown;", @"\U000025be" },
    { @"blacktriangleleft;", @"\U000025c2" },
    { @"blacktriangleright;", @"\U000025b8" },
    { @"blank;", @"\U00002423" },
    { @"blk12;", @"\U00002592" },
    { @"blk14;", @"\U00002591" },
    { @"blk34;", @"\U00002593" },
    { @"block;", @"\U00002588" },
    { @"bne;", @"=\U000020e5" },
    { @"bnequiv;", @"\U00002261\U000020e5" },
    { @"bnot;", @"\U00002310" },
    { @"bopf;", @"\U0001d553" },
    { @"bot;", @"\U000022a5" },
    { @"bottom;", @"\U000022a5" },
    { @"bowtie;", @"\U000022c8" },
    { @"boxDL;", @"\U00002557" },
    { @"boxDR;", @"\U00002554" },
    { @"boxDl;", @"\U00002556" },
    { @"boxDr;", @"\U00002553" },
    { @"boxH;", @"\U00002550" },
    { @"boxHD;", @"\U00002566" },
    { @"boxHU;", @"\U00002569" },
    { @"boxHd;", @"\U00002564" },
    { @"boxHu;", @"\U00002567" },
    { @"boxUL;", @"\U0000255d" },
    { @"boxUR;", @"\U0000255a" },
    { @"boxUl;", @"\U0000255c" },
    { @"boxUr;", @"\U00002559" },
    { @"boxV;", @"\U00002551" },
    { @"boxVH;", @"\U0000256c" },
    { @"boxVL;", @"\U00002563" },
    { @"boxVR;", @"\U00002560" },
    { @"boxVh;", @"\U0000256b" },
    { @"boxVl;", @"\U00002562" },
    { @"boxVr;", @"\U0000255f" },
    { @"boxbox;", @"\U000029c9" },
    { @"boxdL;", @"\U00002555" },
    { @"boxdR;", @"\U00002552" },
    { @"boxdl;", @"\U00002510" },
    { @"boxdr;", @"\U0000250c" },
    { @"boxh;", @"\U00002500" },
    { @"boxhD;", @"\U00002565" },
    { @"boxhU;", @"\U00002568" },
    { @"boxhd;", @"\U0000252c" },
    { @"boxhu;", @"\U00002534" },
    { @"boxminus;", @"\U0000229f" },
    { @"boxplus;", @"\U0000229e" },
    { @"boxtimes;", @"\U000022a0" },
    { @"boxuL;", @"\U0000255b" },
    { @"boxuR;", @"\U00002558" },
    { @"boxul;", @"\U00002518" },
    { @"boxur;", @"\U00002514" },
    { @"boxv;", @"\U00002502" },
    { @"boxvH;", @"\U0000256a" },
    { @"boxvL;", @"\U00002561" },
    { @"boxvR;", @"\U0000255e" },
    { @"boxvh;", @"\U0000253c" },
    { @"boxvl;", @"\U00002524" },
    { @"boxvr;", @"\U0000251c" },
    { @"bprime;", @"\U00002035" },
    { @"breve;", @"\U000002d8" },
    { @"brvbar;", @"\U000000a6" },
    { @"bscr;", @"\U0001d4b7" },
    { @"bsemi;", @"\U0000204f" },
    { @"bsim;", @"\U0000223d" },
    { @"bsime;", @"\U000022cd" },
    { @"bsol;", @"\\" },
    { @"bsolb;", @"\U000029c5" },
    { @"bsolhsub;", @"\U000027c8" },
    { @"bull;", @"\U00002022" },
    { @"bullet;", @"\U00002022" },
    { @"bump;", @"\U0000224e" },
    { @"bumpE;", @"\U00002aae" },
    { @"bumpe;", @"\U0000224f" },
    { @"bumpeq;", @"\U0000224f" },
    { @"cacute;", @"\U00000107" },
    { @"cap;", @"\U00002229" },
    { @"capand;", @"\U00002a44" },
    { @"capbrcup;", @"\U00002a49" },
    { @"capcap;", @"\U00002a4b" },
    { @"capcup;", @"\U00002a47" },
    { @"capdot;", @"\U00002a40" },
    { @"caps;", @"\U00002229\U0000fe00" },
    { @"caret;", @"\U00002041" },
    { @"caron;", @"\U000002c7" },
    { @"ccaps;", @"\U00002a4d" },
    { @"ccaron;", @"\U0000010d" },
    { @"ccedil;", @"\U000000e7" },
    { @"ccirc;", @"\U00000109" },
    { @"ccups;", @"\U00002a4c" },
    { @"ccupssm;", @"\U00002a50" },
    { @"cdot;", @"\U0000010b" },
    { @"cedil;", @"\U000000b8" },
    { @"cemptyv;", @"\U000029b2" },
    { @"cent;", @"\U000000a2" },
    { @"centerdot;", @"\U000000b7" },
    { @"cfr;", @"\U0001d520" },
    { @"chcy;", @"\U00000447" },
    { @"check;", @"\U00002713" },
    { @"checkmark;", @"\U00002713" },
    { @"chi;", @"\U000003c7" },
    { @"cir;", @"\U000025cb" },
    { @"cirE;", @"\U000029c3" },
    { @"circ;", @"\U000002c6" },
    { @"circeq;", @"\U00002257" },
    { @"circlearrowleft;", @"\U000021ba" },
    { @"circlearrowright;", @"\U000021bb" },
    { @"circledR;", @"\U000000ae" },
    { @"circledS;", @"\U000024c8" },
    { @"circledast;", @"\U0000229b" },
    { @"circledcirc;", @"\U0000229a" },
    { @"circleddash;", @"\U0000229d" },
    { @"cire;", @"\U00002257" },
    { @"cirfnint;", @"\U00002a10" },
    { @"cirmid;", @"\U00002aef" },
    { @"cirscir;", @"\U000029c2" },
    { @"clubs;", @"\U00002663" },
    { @"clubsuit;", @"\U00002663" },
    { @"colon;", @":" },
    { @"colone;", @"\U00002254" },
    { @"coloneq;", @"\U00002254" },
    { @"comma;", @"," },
    { @"commat;", @"\U00000040" },
    { @"comp;", @"\U00002201" },
    { @"compfn;", @"\U00002218" },
    { @"complement;", @"\U00002201" },
    { @"complexes;", @"\U00002102" },
    { @"cong;", @"\U00002245" },
    { @"congdot;", @"\U00002a6d" },
    { @"conint;", @"\U0000222e" },
    { @"copf;", @"\U0001d554" },
    { @"coprod;", @"\U00002210" },
    { @"copy;", @"\U000000a9" },
    { @"copysr;", @"\U00002117" },
    { @"crarr;", @"\U000021b5" },
    { @"cross;", @"\U00002717" },
    { @"cscr;", @"\U0001d4b8" },
    { @"csub;", @"\U00002acf" },
    { @"csube;", @"\U00002ad1" },
    { @"csup;", @"\U00002ad0" },
    { @"csupe;", @"\U00002ad2" },
    { @"ctdot;", @"\U000022ef" },
    { @"cudarrl;", @"\U00002938" },
    { @"cudarrr;", @"\U00002935" },
    { @"cuepr;", @"\U000022de" },
    { @"cuesc;", @"\U000022df" },
    { @"cularr;", @"\U000021b6" },
    { @"cularrp;", @"\U0000293d" },
    { @"cup;", @"\U0000222a" },
    { @"cupbrcap;", @"\U00002a48" },
    { @"cupcap;", @"\U00002a46" },
    { @"cupcup;", @"\U00002a4a" },
    { @"cupdot;", @"\U0000228d" },
    { @"cupor;", @"\U00002a45" },
    { @"cups;", @"\U0000222a\U0000fe00" },
    { @"curarr;", @"\U000021b7" },
    { @"curarrm;", @"\U0000293c" },
    { @"curlyeqprec;", @"\U000022de" },
    { @"curlyeqsucc;", @"\U000022df" },
    { @"curlyvee;", @"\U000022ce" },
    { @"curlywedge;", @"\U000022cf" },
    { @"curren;", @"\U000000a4" },
    { @"curvearrowleft;", @"\U000021b6" },
    { @"curvearrowright;", @"\U000021b7" },
    { @"cuvee;", @"\U000022ce" },
    { @"cuwed;", @"\U000022cf" },
    { @"cwconint;", @"\U00002232" },
    { @"cwint;", @"\U00002231" },
    { @"cylcty;", @"\U0000232d" },
    { @"dArr;", @"\U000021d3" },
    { @"dHar;", @"\U00002965" },
    { @"dagger;", @"\U00002020" },
    { @"daleth;", @"\U00002138" },
    { @"darr;", @"\U00002193" },
    { @"dash;", @"\U00002010" },
    { @"dashv;", @"\U000022a3" },
    { @"dbkarow;", @"\U0000290f" },
    { @"dblac;", @"\U000002dd" },
    { @"dcaron;", @"\U0000010f" },
    { @"dcy;", @"\U00000434" },
    { @"dd;", @"\U00002146" },
    { @"ddagger;", @"\U00002021" },
    { @"ddarr;", @"\U000021ca" },
    { @"ddotseq;", @"\U00002a77" },
    { @"deg;", @"\U000000b0" },
    { @"delta;", @"\U000003b4" },
    { @"demptyv;", @"\U000029b1" },
    { @"dfisht;", @"\U0000297f" },
    { @"dfr;", @"\U0001d521" },
    { @"dharl;", @"\U000021c3" },
    { @"dharr;", @"\U000021c2" },
    { @"diam;", @"\U000022c4" },
    { @"diamond;", @"\U000022c4" },
    { @"diamondsuit;", @"\U00002666" },
    { @"diams;", @"\U00002666" },
    { @"die;", @"\U000000a8" },
    { @"digamma;", @"\U000003dd" },
    { @"disin;", @"\U000022f2" },
    { @"div;", @"\U000000f7" },
    { @"divide;", @"\U000000f7" },
    { @"divideontimes;", @"\U000022c7" },
    { @"divonx;", @"\U000022c7" },
    { @"djcy;", @"\U00000452" },
    { @"dlcorn;", @"\U0000231e" },
    { @"dlcrop;", @"\U0000230d" },
    { @"dollar;", @"\U00000024" },
    { @"dopf;", @"\U0001d555" },
    { @"dot;", @"\U000002d9" },
    { @"doteq;", @"\U00002250" },
    { @"doteqdot;", @"\U00002251" },
    { @"dotminus;", @"\U00002238" },
    { @"dotplus;", @"\U00002214" },
    { @"dotsquare;", @"\U000022a1" },
    { @"doublebarwedge;", @"\U00002306" },
    { @"downarrow;", @"\U00002193" },
    { @"downdownarrows;", @"\U000021ca" },
    { @"downharpoonleft;", @"\U000021c3" },
    { @"downharpoonright;", @"\U000021c2" },
    { @"drbkarow;", @"\U00002910" },
    { @"drcorn;", @"\U0000231f" },
    { @"drcrop;", @"\U0000230c" },
    { @"dscr;", @"\U0001d4b9" },
    { @"dscy;", @"\U00000455" },
    { @"dsol;", @"\U000029f6" },
    { @"dstrok;", @"\U00000111" },
    { @"dtdot;", @"\U000022f1" },
    { @"dtri;", @"\U000025bf" },
    { @"dtrif;", @"\U000025be" },
    { @"duarr;", @"\U000021f5" },
    { @"duhar;", @"\U0000296f" },
    { @"dwangle;", @"\U000029a6" },
    { @"dzcy;", @"\U0000045f" },
    { @"dzigrarr;", @"\U000027ff" },
    { @"eDDot;", @"\U00002a77" },
    { @"eDot;", @"\U00002251" },
    { @"eacute;", @"\U000000e9" },
    { @"easter;", @"\U00002a6e" },
    { @"ecaron;", @"\U0000011b" },
    { @"ecir;", @"\U00002256" },
    { @"ecirc;", @"\U000000ea" },
    { @"ecolon;", @"\U00002255" },
    { @"ecy;", @"\U0000044d" },
    { @"edot;", @"\U00000117" },
    { @"ee;", @"\U00002147" },
    { @"efDot;", @"\U00002252" },
    { @"efr;", @"\U0001d522" },
    { @"eg;", @"\U00002a9a" },
    { @"egrave;", @"\U000000e8" },
    { @"egs;", @"\U00002a96" },
    { @"egsdot;", @"\U00002a98" },
    { @"el;", @"\U00002a99" },
    { @"elinters;", @"\U000023e7" },
    { @"ell;", @"\U00002113" },
    { @"els;", @"\U00002a95" },
    { @"elsdot;", @"\U00002a97" },
    { @"emacr;", @"\U00000113" },
    { @"empty;", @"\U00002205" },
    { @"emptyset;", @"\U00002205" },
    { @"emptyv;", @"\U00002205" },
    { @"emsp13;", @"\U00002004" },
    { @"emsp14;", @"\U00002005" },
    { @"emsp;", @"\U00002003" },
    { @"eng;", @"\U0000014b" },
    { @"ensp;", @"\U00002002" },
    { @"eogon;", @"\U00000119" },
    { @"eopf;", @"\U0001d556" },
    { @"epar;", @"\U000022d5" },
    { @"eparsl;", @"\U000029e3" },
    { @"eplus;", @"\U00002a71" },
    { @"epsi;", @"\U000003b5" },
    { @"epsilon;", @"\U000003b5" },
    { @"epsiv;", @"\U000003f5" },
    { @"eqcirc;", @"\U00002256" },
    { @"eqcolon;", @"\U00002255" },
    { @"eqsim;", @"\U00002242" },
    { @"eqslantgtr;", @"\U00002a96" },
    { @"eqslantless;", @"\U00002a95" },
    { @"equals;", @"=" },
    { @"equest;", @"\U0000225f" },
    { @"equiv;", @"\U00002261" },
    { @"equivDD;", @"\U00002a78" },
    { @"eqvparsl;", @"\U000029e5" },
    { @"erDot;", @"\U00002253" },
    { @"erarr;", @"\U00002971" },
    { @"escr;", @"\U0000212f" },
    { @"esdot;", @"\U00002250" },
    { @"esim;", @"\U00002242" },
    { @"eta;", @"\U000003b7" },
    { @"eth;", @"\U000000f0" },
    { @"euml;", @"\U000000eb" },
    { @"euro;", @"\U000020ac" },
    { @"excl;", @"!" },
    { @"exist;", @"\U00002203" },
    { @"expectation;", @"\U00002130" },
    { @"exponentiale;", @"\U00002147" },
    { @"fallingdotseq;", @"\U00002252" },
    { @"fcy;", @"\U00000444" },
    { @"female;", @"\U00002640" },
    { @"ffilig;", @"\U0000fb03" },
    { @"fflig;", @"\U0000fb00" },
    { @"ffllig;", @"\U0000fb04" },
    { @"ffr;", @"\U0001d523" },
    { @"filig;", @"\U0000fb01" },
    { @"fjlig;", @"fj" },
    { @"flat;", @"\U0000266d" },
    { @"fllig;", @"\U0000fb02" },
    { @"fltns;", @"\U000025b1" },
    { @"fnof;", @"\U00000192" },
    { @"fopf;", @"\U0001d557" },
    { @"forall;", @"\U00002200" },
    { @"fork;", @"\U000022d4" },
    { @"forkv;", @"\U00002ad9" },
    { @"fpartint;", @"\U00002a0d" },
    { @"frac12;", @"\U000000bd" },
    { @"frac13;", @"\U00002153" },
    { @"frac14;", @"\U000000bc" },
    { @"frac15;", @"\U00002155" },
    { @"frac16;", @"\U00002159" },
    { @"frac18;", @"\U0000215b" },
    { @"frac23;", @"\U00002154" },
    { @"frac25;", @"\U00002156" },
    { @"frac34;", @"\U000000be" },
    { @"frac35;", @"\U00002157" },
    { @"frac38;", @"\U0000215c" },
    { @"frac45;", @"\U00002158" },
    { @"frac56;", @"\U0000215a" },
    { @"frac58;", @"\U0000215d" },
    { @"frac78;", @"\U0000215e" },
    { @"frasl;", @"\U00002044" },
    { @"frown;", @"\U00002322" },
    { @"fscr;", @"\U0001d4bb" },
    { @"gE;", @"\U00002267" },
    { @"gEl;", @"\U00002a8c" },
    { @"gacute;", @"\U000001f5" },
    { @"gamma;", @"\U000003b3" },
    { @"gammad;", @"\U000003dd" },
    { @"gap;", @"\U00002a86" },
    { @"gbreve;", @"\U0000011f" },
    { @"gcirc;", @"\U0000011d" },
    { @"gcy;", @"\U00000433" },
    { @"gdot;", @"\U00000121" },
    { @"ge;", @"\U00002265" },
    { @"gel;", @"\U000022db" },
    { @"geq;", @"\U00002265" },
    { @"geqq;", @"\U00002267" },
    { @"geqslant;", @"\U00002a7e" },
    { @"ges;", @"\U00002a7e" },
    { @"gescc;", @"\U00002aa9" },
    { @"gesdot;", @"\U00002a80" },
    { @"gesdoto;", @"\U00002a82" },
    { @"gesdotol;", @"\U00002a84" },
    { @"gesl;", @"\U000022db\U0000fe00" },
    { @"gesles;", @"\U00002a94" },
    { @"gfr;", @"\U0001d524" },
    { @"gg;", @"\U0000226b" },
    { @"ggg;", @"\U000022d9" },
    { @"gimel;", @"\U00002137" },
    { @"gjcy;", @"\U00000453" },
    { @"gl;", @"\U00002277" },
    { @"glE;", @"\U00002a92" },
    { @"gla;", @"\U00002aa5" },
    { @"glj;", @"\U00002aa4" },
    { @"gnE;", @"\U00002269" },
    { @"gnap;", @"\U00002a8a" },
    { @"gnapprox;", @"\U00002a8a" },
    { @"gne;", @"\U00002a88" },
    { @"gneq;", @"\U00002a88" },
    { @"gneqq;", @"\U00002269" },
    { @"gnsim;", @"\U000022e7" },
    { @"gopf;", @"\U0001d558" },
    { @"grave;", @"\U00000060" },
    { @"gscr;", @"\U0000210a" },
    { @"gsim;", @"\U00002273" },
    { @"gsime;", @"\U00002a8e" },
    { @"gsiml;", @"\U00002a90" },
    { @"gt;", @">" },
    { @"gtcc;", @"\U00002aa7" },
    { @"gtcir;", @"\U00002a7a" },
    { @"gtdot;", @"\U000022d7" },
    { @"gtlPar;", @"\U00002995" },
    { @"gtquest;", @"\U00002a7c" },
    { @"gtrapprox;", @"\U00002a86" },
    { @"gtrarr;", @"\U00002978" },
    { @"gtrdot;", @"\U000022d7" },
    { @"gtreqless;", @"\U000022db" },
    { @"gtreqqless;", @"\U00002a8c" },
    { @"gtrless;", @"\U00002277" },
    { @"gtrsim;", @"\U00002273" },
    { @"gvertneqq;", @"\U00002269\U0000fe00" },
    { @"gvnE;", @"\U00002269\U0000fe00" },
    { @"hArr;", @"\U000021d4" },
    { @"hairsp;", @"\U0000200a" },
    { @"half;", @"\U000000bd" },
    { @"hamilt;", @"\U0000210b" },
    { @"hardcy;", @"\U0000044a" },
    { @"harr;", @"\U00002194" },
    { @"harrcir;", @"\U00002948" },
    { @"harrw;", @"\U000021ad" },
    { @"hbar;", @"\U0000210f" },
    { @"hcirc;", @"\U00000125" },
    { @"hearts;", @"\U00002665" },
    { @"heartsuit;", @"\U00002665" },
    { @"hellip;", @"\U00002026" },
    { @"hercon;", @"\U000022b9" },
    { @"hfr;", @"\U0001d525" },
    { @"hksearow;", @"\U00002925" },
    { @"hkswarow;", @"\U00002926" },
    { @"hoarr;", @"\U000021ff" },
    { @"homtht;", @"\U0000223b" },
    { @"hookleftarrow;", @"\U000021a9" },
    { @"hookrightarrow;", @"\U000021aa" },
    { @"hopf;", @"\U0001d559" },
    { @"horbar;", @"\U00002015" },
    { @"hscr;", @"\U0001d4bd" },
    { @"hslash;", @"\U0000210f" },
    { @"hstrok;", @"\U00000127" },
    { @"hybull;", @"\U00002043" },
    { @"hyphen;", @"\U00002010" },
    { @"iacute;", @"\U000000ed" },
    { @"ic;", @"\U00002063" },
    { @"icirc;", @"\U000000ee" },
    { @"icy;", @"\U00000438" },
    { @"iecy;", @"\U00000435" },
    { @"iexcl;", @"\U000000a1" },
    { @"iff;", @"\U000021d4" },
    { @"ifr;", @"\U0001d526" },
    { @"igrave;", @"\U000000ec" },
    { @"ii;", @"\U00002148" },
    { @"iiiint;", @"\U00002a0c" },
    { @"iiint;", @"\U0000222d" },
    { @"iinfin;", @"\U000029dc" },
    { @"iiota;", @"\U00002129" },
    { @"ijlig;", @"\U00000133" },
    { @"imacr;", @"\U0000012b" },
    { @"image;", @"\U00002111" },
    { @"imagline;", @"\U00002110" },
    { @"imagpart;", @"\U00002111" },
    { @"imath;", @"\U00000131" },
    { @"imof;", @"\U000022b7" },
    { @"imped;", @"\U000001b5" },
    { @"in;", @"\U00002208" },
    { @"incare;", @"\U00002105" },
    { @"infin;", @"\U0000221e" },
    { @"infintie;", @"\U000029dd" },
    { @"inodot;", @"\U00000131" },
    { @"int;", @"\U0000222b" },
    { @"intcal;", @"\U000022ba" },
    { @"integers;", @"\U00002124" },
    { @"intercal;", @"\U000022ba" },
    { @"intlarhk;", @"\U00002a17" },
    { @"intprod;", @"\U00002a3c" },
    { @"iocy;", @"\U00000451" },
    { @"iogon;", @"\U0000012f" },
    { @"iopf;", @"\U0001d55a" },
    { @"iota;", @"\U000003b9" },
    { @"iprod;", @"\U00002a3c" },
    { @"iquest;", @"\U000000bf" },
    { @"iscr;", @"\U0001d4be" },
    { @"isin;", @"\U00002208" },
    { @"isinE;", @"\U000022f9" },
    { @"isindot;", @"\U000022f5" },
    { @"isins;", @"\U000022f4" },
    { @"isinsv;", @"\U000022f3" },
    { @"isinv;", @"\U00002208" },
    { @"it;", @"\U00002062" },
    { @"itilde;", @"\U00000129" },
    { @"iukcy;", @"\U00000456" },
    { @"iuml;", @"\U000000ef" },
    { @"jcirc;", @"\U00000135" },
    { @"jcy;", @"\U00000439" },
    { @"jfr;", @"\U0001d527" },
    { @"jmath;", @"\U00000237" },
    { @"jopf;", @"\U0001d55b" },
    { @"jscr;", @"\U0001d4bf" },
    { @"jsercy;", @"\U00000458" },
    { @"jukcy;", @"\U00000454" },
    { @"kappa;", @"\U000003ba" },
    { @"kappav;", @"\U000003f0" },
    { @"kcedil;", @"\U00000137" },
    { @"kcy;", @"\U0000043a" },
    { @"kfr;", @"\U0001d528" },
    { @"kgreen;", @"\U00000138" },
    { @"khcy;", @"\U00000445" },
    { @"kjcy;", @"\U0000045c" },
    { @"kopf;", @"\U0001d55c" },
    { @"kscr;", @"\U0001d4c0" },
    { @"lAarr;", @"\U000021da" },
    { @"lArr;", @"\U000021d0" },
    { @"lAtail;", @"\U0000291b" },
    { @"lBarr;", @"\U0000290e" },
    { @"lE;", @"\U00002266" },
    { @"lEg;", @"\U00002a8b" },
    { @"lHar;", @"\U00002962" },
    { @"lacute;", @"\U0000013a" },
    { @"laemptyv;", @"\U000029b4" },
    { @"lagran;", @"\U00002112" },
    { @"lambda;", @"\U000003bb" },
    { @"lang;", @"\U000027e8" },
    { @"langd;", @"\U00002991" },
    { @"langle;", @"\U000027e8" },
    { @"lap;", @"\U00002a85" },
    { @"laquo;", @"\U000000ab" },
    { @"larr;", @"\U00002190" },
    { @"larrb;", @"\U000021e4" },
    { @"larrbfs;", @"\U0000291f" },
    { @"larrfs;", @"\U0000291d" },
    { @"larrhk;", @"\U000021a9" },
    { @"larrlp;", @"\U000021ab" },
    { @"larrpl;", @"\U00002939" },
    { @"larrsim;", @"\U00002973" },
    { @"larrtl;", @"\U000021a2" },
    { @"lat;", @"\U00002aab" },
    { @"latail;", @"\U00002919" },
    { @"late;", @"\U00002aad" },
    { @"lates;", @"\U00002aad\U0000fe00" },
    { @"lbarr;", @"\U0000290c" },
    { @"lbbrk;", @"\U00002772" },
    { @"lbrace;", @"{" },
    { @"lbrack;", @"[" },
    { @"lbrke;", @"\U0000298b" },
    { @"lbrksld;", @"\U0000298f" },
    { @"lbrkslu;", @"\U0000298d" },
    { @"lcaron;", @"\U0000013e" },
    { @"lcedil;", @"\U0000013c" },
    { @"lceil;", @"\U00002308" },
    { @"lcub;", @"{" },
    { @"lcy;", @"\U0000043b" },
    { @"ldca;", @"\U00002936" },
    { @"ldquo;", @"\U0000201c" },
    { @"ldquor;", @"\U0000201e" },
    { @"ldrdhar;", @"\U00002967" },
    { @"ldrushar;", @"\U0000294b" },
    { @"ldsh;", @"\U000021b2" },
    { @"le;", @"\U00002264" },
    { @"leftarrow;", @"\U00002190" },
    { @"leftarrowtail;", @"\U000021a2" },
    { @"leftharpoondown;", @"\U000021bd" },
    { @"leftharpoonup;", @"\U000021bc" },
    { @"leftleftarrows;", @"\U000021c7" },
    { @"leftrightarrow;", @"\U00002194" },
    { @"leftrightarrows;", @"\U000021c6" },
    { @"leftrightharpoons;", @"\U000021cb" },
    { @"leftrightsquigarrow;", @"\U000021ad" },
    { @"leftthreetimes;", @"\U000022cb" },
    { @"leg;", @"\U000022da" },
    { @"leq;", @"\U00002264" },
    { @"leqq;", @"\U00002266" },
    { @"leqslant;", @"\U00002a7d" },
    { @"les;", @"\U00002a7d" },
    { @"lescc;", @"\U00002aa8" },
    { @"lesdot;", @"\U00002a7f" },
    { @"lesdoto;", @"\U00002a81" },
    { @"lesdotor;", @"\U00002a83" },
    { @"lesg;", @"\U000022da\U0000fe00" },
    { @"lesges;", @"\U00002a93" },
    { @"lessapprox;", @"\U00002a85" },
    { @"lessdot;", @"\U000022d6" },
    { @"lesseqgtr;", @"\U000022da" },
    { @"lesseqqgtr;", @"\U00002a8b" },
    { @"lessgtr;", @"\U00002276" },
    { @"lesssim;", @"\U00002272" },
    { @"lfisht;", @"\U0000297c" },
    { @"lfloor;", @"\U0000230a" },
    { @"lfr;", @"\U0001d529" },
    { @"lg;", @"\U00002276" },
    { @"lgE;", @"\U00002a91" },
    { @"lhard;", @"\U000021bd" },
    { @"lharu;", @"\U000021bc" },
    { @"lharul;", @"\U0000296a" },
    { @"lhblk;", @"\U00002584" },
    { @"ljcy;", @"\U00000459" },
    { @"ll;", @"\U0000226a" },
    { @"llarr;", @"\U000021c7" },
    { @"llcorner;", @"\U0000231e" },
    { @"llhard;", @"\U0000296b" },
    { @"lltri;", @"\U000025fa" },
    { @"lmidot;", @"\U00000140" },
    { @"lmoust;", @"\U000023b0" },
    { @"lmoustache;", @"\U000023b0" },
    { @"lnE;", @"\U00002268" },
    { @"lnap;", @"\U00002a89" },
    { @"lnapprox;", @"\U00002a89" },
    { @"lne;", @"\U00002a87" },
    { @"lneq;", @"\U00002a87" },
    { @"lneqq;", @"\U00002268" },
    { @"lnsim;", @"\U000022e6" },
    { @"loang;", @"\U000027ec" },
    { @"loarr;", @"\U000021fd" },
    { @"lobrk;", @"\U000027e6" },
    { @"longleftarrow;", @"\U000027f5" },
    { @"longleftrightarrow;", @"\U000027f7" },
    { @"longmapsto;", @"\U000027fc" },
    { @"longrightarrow;", @"\U000027f6" },
    { @"looparrowleft;", @"\U000021ab" },
    { @"looparrowright;", @"\U000021ac" },
    { @"lopar;", @"\U00002985" },
    { @"lopf;", @"\U0001d55d" },
    { @"loplus;", @"\U00002a2d" },
    { @"lotimes;", @"\U00002a34" },
    { @"lowast;", @"\U00002217" },
    { @"lowbar;", @"_" },
    { @"loz;", @"\U000025ca" },
    { @"lozenge;", @"\U000025ca" },
    { @"lozf;", @"\U000029eb" },
    { @"lpar;", @"(" },
    { @"lparlt;", @"\U00002993" },
    { @"lrarr;", @"\U000021c6" },
    { @"lrcorner;", @"\U0000231f" },
    { @"lrhar;", @"\U000021cb" },
    { @"lrhard;", @"\U0000296d" },
    { @"lrm;", @"\U0000200e" },
    { @"lrtri;", @"\U000022bf" },
    { @"lsaquo;", @"\U00002039" },
    { @"lscr;", @"\U0001d4c1" },
    { @"lsh;", @"\U000021b0" },
    { @"lsim;", @"\U00002272" },
    { @"lsime;", @"\U00002a8d" },
    { @"lsimg;", @"\U00002a8f" },
    { @"lsqb;", @"[" },
    { @"lsquo;", @"\U00002018" },
    { @"lsquor;", @"\U0000201a" },
    { @"lstrok;", @"\U00000142" },
    { @"lt;", @"<" },
    { @"ltcc;", @"\U00002aa6" },
    { @"ltcir;", @"\U00002a79" },
    { @"ltdot;", @"\U000022d6" },
    { @"lthree;", @"\U000022cb" },
    { @"ltimes;", @"\U000022c9" },
    { @"ltlarr;", @"\U00002976" },
    { @"ltquest;", @"\U00002a7b" },
    { @"ltrPar;", @"\U00002996" },
    { @"ltri;", @"\U000025c3" },
    { @"ltrie;", @"\U000022b4" },
    { @"ltrif;", @"\U000025c2" },
    { @"lurdshar;", @"\U0000294a" },
    { @"luruhar;", @"\U00002966" },
    { @"lvertneqq;", @"\U00002268\U0000fe00" },
    { @"lvnE;", @"\U00002268\U0000fe00" },
    { @"mDDot;", @"\U0000223a" },
    { @"macr;", @"\U000000af" },
    { @"male;", @"\U00002642" },
    { @"malt;", @"\U00002720" },
    { @"maltese;", @"\U00002720" },
    { @"map;", @"\U000021a6" },
    { @"mapsto;", @"\U000021a6" },
    { @"mapstodown;", @"\U000021a7" },
    { @"mapstoleft;", @"\U000021a4" },
    { @"mapstoup;", @"\U000021a5" },
    { @"marker;", @"\U000025ae" },
    { @"mcomma;", @"\U00002a29" },
    { @"mcy;", @"\U0000043c" },
    { @"mdash;", @"\U00002014" },
    { @"measuredangle;", @"\U00002221" },
    { @"mfr;", @"\U0001d52a" },
    { @"mho;", @"\U00002127" },
    { @"micro;", @"\U000000b5" },
    { @"mid;", @"\U00002223" },
    { @"midast;", @"*" },
    { @"midcir;", @"\U00002af0" },
    { @"middot;", @"\U000000b7" },
    { @"minus;", @"\U00002212" },
    { @"minusb;", @"\U0000229f" },
    { @"minusd;", @"\U00002238" },
    { @"minusdu;", @"\U00002a2a" },
    { @"mlcp;", @"\U00002adb" },
    { @"mldr;", @"\U00002026" },
    { @"mnplus;", @"\U00002213" },
    { @"models;", @"\U000022a7" },
    { @"mopf;", @"\U0001d55e" },
    { @"mp;", @"\U00002213" },
    { @"mscr;", @"\U0001d4c2" },
    { @"mstpos;", @"\U0000223e" },
    { @"mu;", @"\U000003bc" },
    { @"multimap;", @"\U000022b8" },
    { @"mumap;", @"\U000022b8" },
    { @"nGg;", @"\U000022d9\U00000338" },
    { @"nGt;", @"\U0000226b\U000020d2" },
    { @"nGtv;", @"\U0000226b\U00000338" },
    { @"nLeftarrow;", @"\U000021cd" },
    { @"nLeftrightarrow;", @"\U000021ce" },
    { @"nLl;", @"\U000022d8\U00000338" },
    { @"nLt;", @"\U0000226a\U000020d2" },
    { @"nLtv;", @"\U0000226a\U00000338" },
    { @"nRightarrow;", @"\U000021cf" },
    { @"nVDash;", @"\U000022af" },
    { @"nVdash;", @"\U000022ae" },
    { @"nabla;", @"\U00002207" },
    { @"nacute;", @"\U00000144" },
    { @"nang;", @"\U00002220\U000020d2" },
    { @"nap;", @"\U00002249" },
    { @"napE;", @"\U00002a70\U00000338" },
    { @"napid;", @"\U0000224b\U00000338" },
    { @"napos;", @"\U00000149" },
    { @"napprox;", @"\U00002249" },
    { @"natur;", @"\U0000266e" },
    { @"natural;", @"\U0000266e" },
    { @"naturals;", @"\U00002115" },
    { @"nbsp;", @"\U000000a0" },
    { @"nbump;", @"\U0000224e\U00000338" },
    { @"nbumpe;", @"\U0000224f\U00000338" },
    { @"ncap;", @"\U00002a43" },
    { @"ncaron;", @"\U00000148" },
    { @"ncedil;", @"\U00000146" },
    { @"ncong;", @"\U00002247" },
    { @"ncongdot;", @"\U00002a6d\U00000338" },
    { @"ncup;", @"\U00002a42" },
    { @"ncy;", @"\U0000043d" },
    { @"ndash;", @"\U00002013" },
    { @"ne;", @"\U00002260" },
    { @"neArr;", @"\U000021d7" },
    { @"nearhk;", @"\U00002924" },
    { @"nearr;", @"\U00002197" },
    { @"nearrow;", @"\U00002197" },
    { @"nedot;", @"\U00002250\U00000338" },
    { @"nequiv;", @"\U00002262" },
    { @"nesear;", @"\U00002928" },
    { @"nesim;", @"\U00002242\U00000338" },
    { @"nexist;", @"\U00002204" },
    { @"nexists;", @"\U00002204" },
    { @"nfr;", @"\U0001d52b" },
    { @"ngE;", @"\U00002267\U00000338" },
    { @"nge;", @"\U00002271" },
    { @"ngeq;", @"\U00002271" },
    { @"ngeqq;", @"\U00002267\U00000338" },
    { @"ngeqslant;", @"\U00002a7e\U00000338" },
    { @"nges;", @"\U00002a7e\U00000338" },
    { @"ngsim;", @"\U00002275" },
    { @"ngt;", @"\U0000226f" },
    { @"ngtr;", @"\U0000226f" },
    { @"nhArr;", @"\U000021ce" },
    { @"nharr;", @"\U000021ae" },
    { @"nhpar;", @"\U00002af2" },
    { @"ni;", @"\U0000220b" },
    { @"nis;", @"\U000022fc" },
    { @"nisd;", @"\U000022fa" },
    { @"niv;", @"\U0000220b" },
    { @"njcy;", @"\U0000045a" },
    { @"nlArr;", @"\U000021cd" },
    { @"nlE;", @"\U00002266\U00000338" },
    { @"nlarr;", @"\U0000219a" },
    { @"nldr;", @"\U00002025" },
    { @"nle;", @"\U00002270" },
    { @"nleftarrow;", @"\U0000219a" },
    { @"nleftrightarrow;", @"\U000021ae" },
    { @"nleq;", @"\U00002270" },
    { @"nleqq;", @"\U00002266\U00000338" },
    { @"nleqslant;", @"\U00002a7d\U00000338" },
    { @"nles;", @"\U00002a7d\U00000338" },
    { @"nless;", @"\U0000226e" },
    { @"nlsim;", @"\U00002274" },
    { @"nlt;", @"\U0000226e" },
    { @"nltri;", @"\U000022ea" },
    { @"nltrie;", @"\U000022ec" },
    { @"nmid;", @"\U00002224" },
    { @"nopf;", @"\U0001d55f" },
    { @"not;", @"\U000000ac" },
    { @"notin;", @"\U00002209" },
    { @"notinE;", @"\U000022f9\U00000338" },
    { @"notindot;", @"\U000022f5\U00000338" },
    { @"notinva;", @"\U00002209" },
    { @"notinvb;", @"\U000022f7" },
    { @"notinvc;", @"\U000022f6" },
    { @"notni;", @"\U0000220c" },
    { @"notniva;", @"\U0000220c" },
    { @"notnivb;", @"\U000022fe" },
    { @"notnivc;", @"\U000022fd" },
    { @"npar;", @"\U00002226" },
    { @"nparallel;", @"\U00002226" },
    { @"nparsl;", @"\U00002afd\U000020e5" },
    { @"npart;", @"\U00002202\U00000338" },
    { @"npolint;", @"\U00002a14" },
    { @"npr;", @"\U00002280" },
    { @"nprcue;", @"\U000022e0" },
    { @"npre;", @"\U00002aaf\U00000338" },
    { @"nprec;", @"\U00002280" },
    { @"npreceq;", @"\U00002aaf\U00000338" },
    { @"nrArr;", @"\U000021cf" },
    { @"nrarr;", @"\U0000219b" },
    { @"nrarrc;", @"\U00002933\U00000338" },
    { @"nrarrw;", @"\U0000219d\U00000338" },
    { @"nrightarrow;", @"\U0000219b" },
    { @"nrtri;", @"\U000022eb" },
    { @"nrtrie;", @"\U000022ed" },
    { @"nsc;", @"\U00002281" },
    { @"nsccue;", @"\U000022e1" },
    { @"nsce;", @"\U00002ab0\U00000338" },
    { @"nscr;", @"\U0001d4c3" },
    { @"nshortmid;", @"\U00002224" },
    { @"nshortparallel;", @"\U00002226" },
    { @"nsim;", @"\U00002241" },
    { @"nsime;", @"\U00002244" },
    { @"nsimeq;", @"\U00002244" },
    { @"nsmid;", @"\U00002224" },
    { @"nspar;", @"\U00002226" },
    { @"nsqsube;", @"\U000022e2" },
    { @"nsqsupe;", @"\U000022e3" },
    { @"nsub;", @"\U00002284" },
    { @"nsubE;", @"\U00002ac5\U00000338" },
    { @"nsube;", @"\U00002288" },
    { @"nsubset;", @"\U00002282\U000020d2" },
    { @"nsubseteq;", @"\U00002288" },
    { @"nsubseteqq;", @"\U00002ac5\U00000338" },
    { @"nsucc;", @"\U00002281" },
    { @"nsucceq;", @"\U00002ab0\U00000338" },
    { @"nsup;", @"\U00002285" },
    { @"nsupE;", @"\U00002ac6\U00000338" },
    { @"nsupe;", @"\U00002289" },
    { @"nsupset;", @"\U00002283\U000020d2" },
    { @"nsupseteq;", @"\U00002289" },
    { @"nsupseteqq;", @"\U00002ac6\U00000338" },
    { @"ntgl;", @"\U00002279" },
    { @"ntilde;", @"\U000000f1" },
    { @"ntlg;", @"\U00002278" },
    { @"ntriangleleft;", @"\U000022ea" },
    { @"ntrianglelefteq;", @"\U000022ec" },
    { @"ntriangleright;", @"\U000022eb" },
    { @"ntrianglerighteq;", @"\U000022ed" },
    { @"nu;", @"\U000003bd" },
    { @"num;", @"#" },
    { @"numero;", @"\U00002116" },
    { @"numsp;", @"\U00002007" },
    { @"nvDash;", @"\U000022ad" },
    { @"nvHarr;", @"\U00002904" },
    { @"nvap;", @"\U0000224d\U000020d2" },
    { @"nvdash;", @"\U000022ac" },
    { @"nvge;", @"\U00002265\U000020d2" },
    { @"nvgt;", @">\U000020d2" },
    { @"nvinfin;", @"\U000029de" },
    { @"nvlArr;", @"\U00002902" },
    { @"nvle;", @"\U00002264\U000020d2" },
    { @"nvlt;", @"<\U000020d2" },
    { @"nvltrie;", @"\U000022b4\U000020d2" },
    { @"nvrArr;", @"\U00002903" },
    { @"nvrtrie;", @"\U000022b5\U000020d2" },
    { @"nvsim;", @"\U0000223c\U000020d2" },
    { @"nwArr;", @"\U000021d6" },
    { @"nwarhk;", @"\U00002923" },
    { @"nwarr;", @"\U00002196" },
    { @"nwarrow;", @"\U00002196" },
    { @"nwnear;", @"\U00002927" },
    { @"oS;", @"\U000024c8" },
    { @"oacute;", @"\U000000f3" },
    { @"oast;", @"\U0000229b" },
    { @"ocir;", @"\U0000229a" },
    { @"ocirc;", @"\U000000f4" },
    { @"ocy;", @"\U0000043e" },
    { @"odash;", @"\U0000229d" },
    { @"odblac;", @"\U00000151" },
    { @"odiv;", @"\U00002a38" },
    { @"odot;", @"\U00002299" },
    { @"odsold;", @"\U000029bc" },
    { @"oelig;", @"\U00000153" },
    { @"ofcir;", @"\U000029bf" },
    { @"ofr;", @"\U0001d52c" },
    { @"ogon;", @"\U000002db" },
    { @"ograve;", @"\U000000f2" },
    { @"ogt;", @"\U000029c1" },
    { @"ohbar;", @"\U000029b5" },
    { @"ohm;", @"\U000003a9" },
    { @"oint;", @"\U0000222e" },
    { @"olarr;", @"\U000021ba" },
    { @"olcir;", @"\U000029be" },
    { @"olcross;", @"\U000029bb" },
    { @"oline;", @"\U0000203e" },
    { @"olt;", @"\U000029c0" },
    { @"omacr;", @"\U0000014d" },
    { @"omega;", @"\U000003c9" },
    { @"omicron;", @"\U000003bf" },
    { @"omid;", @"\U000029b6" },
    { @"ominus;", @"\U00002296" },
    { @"oopf;", @"\U0001d560" },
    { @"opar;", @"\U000029b7" },
    { @"operp;", @"\U000029b9" },
    { @"oplus;", @"\U00002295" },
    { @"or;", @"\U00002228" },
    { @"orarr;", @"\U000021bb" },
    { @"ord;", @"\U00002a5d" },
    { @"order;", @"\U00002134" },
    { @"orderof;", @"\U00002134" },
    { @"ordf;", @"\U000000aa" },
    { @"ordm;", @"\U000000ba" },
    { @"origof;", @"\U000022b6" },
    { @"oror;", @"\U00002a56" },
    { @"orslope;", @"\U00002a57" },
    { @"orv;", @"\U00002a5b" },
    { @"oscr;", @"\U00002134" },
    { @"oslash;", @"\U000000f8" },
    { @"osol;", @"\U00002298" },
    { @"otilde;", @"\U000000f5" },
    { @"otimes;", @"\U00002297" },
    { @"otimesas;", @"\U00002a36" },
    { @"ouml;", @"\U000000f6" },
    { @"ovbar;", @"\U0000233d" },
    { @"par;", @"\U00002225" },
    { @"para;", @"\U000000b6" },
    { @"parallel;", @"\U00002225" },
    { @"parsim;", @"\U00002af3" },
    { @"parsl;", @"\U00002afd" },
    { @"part;", @"\U00002202" },
    { @"pcy;", @"\U0000043f" },
    { @"percnt;", @"%" },
    { @"period;", @"." },
    { @"permil;", @"\U00002030" },
    { @"perp;", @"\U000022a5" },
    { @"pertenk;", @"\U00002031" },
    { @"pfr;", @"\U0001d52d" },
    { @"phi;", @"\U000003c6" },
    { @"phiv;", @"\U000003d5" },
    { @"phmmat;", @"\U00002133" },
    { @"phone;", @"\U0000260e" },
    { @"pi;", @"\U000003c0" },
    { @"pitchfork;", @"\U000022d4" },
    { @"piv;", @"\U000003d6" },
    { @"planck;", @"\U0000210f" },
    { @"planckh;", @"\U0000210e" },
    { @"plankv;", @"\U0000210f" },
    { @"plus;", @"+" },
    { @"plusacir;", @"\U00002a23" },
    { @"plusb;", @"\U0000229e" },
    { @"pluscir;", @"\U00002a22" },
    { @"plusdo;", @"\U00002214" },
    { @"plusdu;", @"\U00002a25" },
    { @"pluse;", @"\U00002a72" },
    { @"plusmn;", @"\U000000b1" },
    { @"plussim;", @"\U00002a26" },
    { @"plustwo;", @"\U00002a27" },
    { @"pm;", @"\U000000b1" },
    { @"pointint;", @"\U00002a15" },
    { @"popf;", @"\U0001d561" },
    { @"pound;", @"\U000000a3" },
    { @"pr;", @"\U0000227a" },
    { @"prE;", @"\U00002ab3" },
    { @"prap;", @"\U00002ab7" },
    { @"prcue;", @"\U0000227c" },
    { @"pre;", @"\U00002aaf" },
    { @"prec;", @"\U0000227a" },
    { @"precapprox;", @"\U00002ab7" },
    { @"preccurlyeq;", @"\U0000227c" },
    { @"preceq;", @"\U00002aaf" },
    { @"precnapprox;", @"\U00002ab9" },
    { @"precneqq;", @"\U00002ab5" },
    { @"precnsim;", @"\U000022e8" },
    { @"precsim;", @"\U0000227e" },
    { @"prime;", @"\U00002032" },
    { @"primes;", @"\U00002119" },
    { @"prnE;", @"\U00002ab5" },
    { @"prnap;", @"\U00002ab9" },
    { @"prnsim;", @"\U000022e8" },
    { @"prod;", @"\U0000220f" },
    { @"profalar;", @"\U0000232e" },
    { @"profline;", @"\U00002312" },
    { @"profsurf;", @"\U00002313" },
    { @"prop;", @"\U0000221d" },
    { @"propto;", @"\U0000221d" },
    { @"prsim;", @"\U0000227e" },
    { @"prurel;", @"\U000022b0" },
    { @"pscr;", @"\U0001d4c5" },
    { @"psi;", @"\U000003c8" },
    { @"puncsp;", @"\U00002008" },
    { @"qfr;", @"\U0001d52e" },
    { @"qint;", @"\U00002a0c" },
    { @"qopf;", @"\U0001d562" },
    { @"qprime;", @"\U00002057" },
    { @"qscr;", @"\U0001d4c6" },
    { @"quaternions;", @"\U0000210d" },
    { @"quatint;", @"\U00002a16" },
    { @"quest;", @"?" },
    { @"questeq;", @"\U0000225f" },
    { @"quot;", @"\"" },
    { @"rAarr;", @"\U000021db" },
    { @"rArr;", @"\U000021d2" },
    { @"rAtail;", @"\U0000291c" },
    { @"rBarr;", @"\U0000290f" },
    { @"rHar;", @"\U00002964" },
    { @"race;", @"\U0000223d\U00000331" },
    { @"racute;", @"\U00000155" },
    { @"radic;", @"\U0000221a" },
    { @"raemptyv;", @"\U000029b3" },
    { @"rang;", @"\U000027e9" },
    { @"rangd;", @"\U00002992" },
    { @"range;", @"\U000029a5" },
    { @"rangle;", @"\U000027e9" },
    { @"raquo;", @"\U000000bb" },
    { @"rarr;", @"\U00002192" },
    { @"rarrap;", @"\U00002975" },
    { @"rarrb;", @"\U000021e5" },
    { @"rarrbfs;", @"\U00002920" },
    { @"rarrc;", @"\U00002933" },
    { @"rarrfs;", @"\U0000291e" },
    { @"rarrhk;", @"\U000021aa" },
    { @"rarrlp;", @"\U000021ac" },
    { @"rarrpl;", @"\U00002945" },
    { @"rarrsim;", @"\U00002974" },
    { @"rarrtl;", @"\U000021a3" },
    { @"rarrw;", @"\U0000219d" },
    { @"ratail;", @"\U0000291a" },
    { @"ratio;", @"\U00002236" },
    { @"rationals;", @"\U0000211a" },
    { @"rbarr;", @"\U0000290d" },
    { @"rbbrk;", @"\U00002773" },
    { @"rbrace;", @"}" },
    { @"rbrack;", @"]" },
    { @"rbrke;", @"\U0000298c" },
    { @"rbrksld;", @"\U0000298e" },
    { @"rbrkslu;", @"\U00002990" },
    { @"rcaron;", @"\U00000159" },
    { @"rcedil;", @"\U00000157" },
    { @"rceil;", @"\U00002309" },
    { @"rcub;", @"}" },
    { @"rcy;", @"\U00000440" },
    { @"rdca;", @"\U00002937" },
    { @"rdldhar;", @"\U00002969" },
    { @"rdquo;", @"\U0000201d" },
    { @"rdquor;", @"\U0000201d" },
    { @"rdsh;", @"\U000021b3" },
    { @"real;", @"\U0000211c" },
    { @"realine;", @"\U0000211b" },
    { @"realpart;", @"\U0000211c" },
    { @"reals;", @"\U0000211d" },
    { @"rect;", @"\U000025ad" },
    { @"reg;", @"\U000000ae" },
    { @"rfisht;", @"\U0000297d" },
    { @"rfloor;", @"\U0000230b" },
    { @"rfr;", @"\U0001d52f" },
    { @"rhard;", @"\U000021c1" },
    { @"rharu;", @"\U000021c0" },
    { @"rharul;", @"\U0000296c" },
    { @"rho;", @"\U000003c1" },
    { @"rhov;", @"\U000003f1" },
    { @"rightarrow;", @"\U00002192" },
    { @"rightarrowtail;", @"\U000021a3" },
    { @"rightharpoondown;", @"\U000021c1" },
    { @"rightharpoonup;", @"\U000021c0" },
    { @"rightleftarrows;", @"\U000021c4" },
    { @"rightleftharpoons;", @"\U000021cc" },
    { @"rightrightarrows;", @"\U000021c9" },
    { @"rightsquigarrow;", @"\U0000219d" },
    { @"rightthreetimes;", @"\U000022cc" },
    { @"ring;", @"\U000002da" },
    { @"risingdotseq;", @"\U00002253" },
    { @"rlarr;", @"\U000021c4" },
    { @"rlhar;", @"\U000021cc" },
    { @"rlm;", @"\U0000200f" },
    { @"rmoust;", @"\U000023b1" },
    { @"rmoustache;", @"\U000023b1" },
    { @"rnmid;", @"\U00002aee" },
    { @"roang;", @"\U000027ed" },
    { @"roarr;", @"\U000021fe" },
    { @"robrk;", @"\U000027e7" },
    { @"ropar;", @"\U00002986" },
    { @"ropf;", @"\U0001d563" },
    { @"roplus;", @"\U00002a2e" },
    { @"rotimes;", @"\U00002a35" },
    { @"rpar;", @")" },
    { @"rpargt;", @"\U00002994" },
    { @"rppolint;", @"\U00002a12" },
    { @"rrarr;", @"\U000021c9" },
    { @"rsaquo;", @"\U0000203a" },
    { @"rscr;", @"\U0001d4c7" },
    { @"rsh;", @"\U000021b1" },
    { @"rsqb;", @"]" },
    { @"rsquo;", @"\U00002019" },
    { @"rsquor;", @"\U00002019" },
    { @"rthree;", @"\U000022cc" },
    { @"rtimes;", @"\U000022ca" },
    { @"rtri;", @"\U000025b9" },
    { @"rtrie;", @"\U000022b5" },
    { @"rtrif;", @"\U000025b8" },
    { @"rtriltri;", @"\U000029ce" },
    { @"ruluhar;", @"\U00002968" },
    { @"rx;", @"\U0000211e" },
    { @"sacute;", @"\U0000015b" },
    { @"sbquo;", @"\U0000201a" },
    { @"sc;", @"\U0000227b" },
    { @"scE;", @"\U00002ab4" },
    { @"scap;", @"\U00002ab8" },
    { @"scaron;", @"\U00000161" },
    { @"sccue;", @"\U0000227d" },
    { @"sce;", @"\U00002ab0" },
    { @"scedil;", @"\U0000015f" },
    { @"scirc;", @"\U0000015d" },
    { @"scnE;", @"\U00002ab6" },
    { @"scnap;", @"\U00002aba" },
    { @"scnsim;", @"\U000022e9" },
    { @"scpolint;", @"\U00002a13" },
    { @"scsim;", @"\U0000227f" },
    { @"scy;", @"\U00000441" },
    { @"sdot;", @"\U000022c5" },
    { @"sdotb;", @"\U000022a1" },
    { @"sdote;", @"\U00002a66" },
    { @"seArr;", @"\U000021d8" },
    { @"searhk;", @"\U00002925" },
    { @"searr;", @"\U00002198" },
    { @"searrow;", @"\U00002198" },
    { @"sect;", @"\U000000a7" },
    { @"semi;", @";" },
    { @"seswar;", @"\U00002929" },
    { @"setminus;", @"\U00002216" },
    { @"setmn;", @"\U00002216" },
    { @"sext;", @"\U00002736" },
    { @"sfr;", @"\U0001d530" },
    { @"sfrown;", @"\U00002322" },
    { @"sharp;", @"\U0000266f" },
    { @"shchcy;", @"\U00000449" },
    { @"shcy;", @"\U00000448" },
    { @"shortmid;", @"\U00002223" },
    { @"shortparallel;", @"\U00002225" },
    { @"shy;", @"\U000000ad" },
    { @"sigma;", @"\U000003c3" },
    { @"sigmaf;", @"\U000003c2" },
    { @"sigmav;", @"\U000003c2" },
    { @"sim;", @"\U0000223c" },
    { @"simdot;", @"\U00002a6a" },
    { @"sime;", @"\U00002243" },
    { @"simeq;", @"\U00002243" },
    { @"simg;", @"\U00002a9e" },
    { @"simgE;", @"\U00002aa0" },
    { @"siml;", @"\U00002a9d" },
    { @"simlE;", @"\U00002a9f" },
    { @"simne;", @"\U00002246" },
    { @"simplus;", @"\U00002a24" },
    { @"simrarr;", @"\U00002972" },
    { @"slarr;", @"\U00002190" },
    { @"smallsetminus;", @"\U00002216" },
    { @"smashp;", @"\U00002a33" },
    { @"smeparsl;", @"\U000029e4" },
    { @"smid;", @"\U00002223" },
    { @"smile;", @"\U00002323" },
    { @"smt;", @"\U00002aaa" },
    { @"smte;", @"\U00002aac" },
    { @"smtes;", @"\U00002aac\U0000fe00" },
    { @"softcy;", @"\U0000044c" },
    { @"sol;", @"/" },
    { @"solb;", @"\U000029c4" },
    { @"solbar;", @"\U0000233f" },
    { @"sopf;", @"\U0001d564" },
    { @"spades;", @"\U00002660" },
    { @"spadesuit;", @"\U00002660" },
    { @"spar;", @"\U00002225" },
    { @"sqcap;", @"\U00002293" },
    { @"sqcaps;", @"\U00002293\U0000fe00" },
    { @"sqcup;", @"\U00002294" },
    { @"sqcups;", @"\U00002294\U0000fe00" },
    { @"sqsub;", @"\U0000228f" },
    { @"sqsube;", @"\U00002291" },
    { @"sqsubset;", @"\U0000228f" },
    { @"sqsubseteq;", @"\U00002291" },
    { @"sqsup;", @"\U00002290" },
    { @"sqsupe;", @"\U00002292" },
    { @"sqsupset;", @"\U00002290" },
    { @"sqsupseteq;", @"\U00002292" },
    { @"squ;", @"\U000025a1" },
    { @"square;", @"\U000025a1" },
    { @"squarf;", @"\U000025aa" },
    { @"squf;", @"\U000025aa" },
    { @"srarr;", @"\U00002192" },
    { @"sscr;", @"\U0001d4c8" },
    { @"ssetmn;", @"\U00002216" },
    { @"ssmile;", @"\U00002323" },
    { @"sstarf;", @"\U000022c6" },
    { @"star;", @"\U00002606" },
    { @"starf;", @"\U00002605" },
    { @"straightepsilon;", @"\U000003f5" },
    { @"straightphi;", @"\U000003d5" },
    { @"strns;", @"\U000000af" },
    { @"sub;", @"\U00002282" },
    { @"subE;", @"\U00002ac5" },
    { @"subdot;", @"\U00002abd" },
    { @"sube;", @"\U00002286" },
    { @"subedot;", @"\U00002ac3" },
    { @"submult;", @"\U00002ac1" },
    { @"subnE;", @"\U00002acb" },
    { @"subne;", @"\U0000228a" },
    { @"subplus;", @"\U00002abf" },
    { @"subrarr;", @"\U00002979" },
    { @"subset;", @"\U00002282" },
    { @"subseteq;", @"\U00002286" },
    { @"subseteqq;", @"\U00002ac5" },
    { @"subsetneq;", @"\U0000228a" },
    { @"subsetneqq;", @"\U00002acb" },
    { @"subsim;", @"\U00002ac7" },
    { @"subsub;", @"\U00002ad5" },
    { @"subsup;", @"\U00002ad3" },
    { @"succ;", @"\U0000227b" },
    { @"succapprox;", @"\U00002ab8" },
    { @"succcurlyeq;", @"\U0000227d" },
    { @"succeq;", @"\U00002ab0" },
    { @"succnapprox;", @"\U00002aba" },
    { @"succneqq;", @"\U00002ab6" },
    { @"succnsim;", @"\U000022e9" },
    { @"succsim;", @"\U0000227f" },
    { @"sum;", @"\U00002211" },
    { @"sung;", @"\U0000266a" },
    { @"sup1;", @"\U000000b9" },
    { @"sup2;", @"\U000000b2" },
    { @"sup3;", @"\U000000b3" },
    { @"sup;", @"\U00002283" },
    { @"supE;", @"\U00002ac6" },
    { @"supdot;", @"\U00002abe" },
    { @"supdsub;", @"\U00002ad8" },
    { @"supe;", @"\U00002287" },
    { @"supedot;", @"\U00002ac4" },
    { @"suphsol;", @"\U000027c9" },
    { @"suphsub;", @"\U00002ad7" },
    { @"suplarr;", @"\U0000297b" },
    { @"supmult;", @"\U00002ac2" },
    { @"supnE;", @"\U00002acc" },
    { @"supne;", @"\U0000228b" },
    { @"supplus;", @"\U00002ac0" },
    { @"supset;", @"\U00002283" },
    { @"supseteq;", @"\U00002287" },
    { @"supseteqq;", @"\U00002ac6" },
    { @"supsetneq;", @"\U0000228b" },
    { @"supsetneqq;", @"\U00002acc" },
    { @"supsim;", @"\U00002ac8" },
    { @"supsub;", @"\U00002ad4" },
    { @"supsup;", @"\U00002ad6" },
    { @"swArr;", @"\U000021d9" },
    { @"swarhk;", @"\U00002926" },
    { @"swarr;", @"\U00002199" },
    { @"swarrow;", @"\U00002199" },
    { @"swnwar;", @"\U0000292a" },
    { @"szlig;", @"\U000000df" },
    { @"target;", @"\U00002316" },
    { @"tau;", @"\U000003c4" },
    { @"tbrk;", @"\U000023b4" },
    { @"tcaron;", @"\U00000165" },
    { @"tcedil;", @"\U00000163" },
    { @"tcy;", @"\U00000442" },
    { @"tdot;", @"\U000020db" },
    { @"telrec;", @"\U00002315" },
    { @"tfr;", @"\U0001d531" },
    { @"there4;", @"\U00002234" },
    { @"therefore;", @"\U00002234" },
    { @"theta;", @"\U000003b8" },
    { @"thetasym;", @"\U000003d1" },
    { @"thetav;", @"\U000003d1" },
    { @"thickapprox;", @"\U00002248" },
    { @"thicksim;", @"\U0000223c" },
    { @"thinsp;", @"\U00002009" },
    { @"thkap;", @"\U00002248" },
    { @"thksim;", @"\U0000223c" },
    { @"thorn;", @"\U000000fe" },
    { @"tilde;", @"\U000002dc" },
    { @"times;", @"\U000000d7" },
    { @"timesb;", @"\U000022a0" },
    { @"timesbar;", @"\U00002a31" },
    { @"timesd;", @"\U00002a30" },
    { @"tint;", @"\U0000222d" },
    { @"toea;", @"\U00002928" },
    { @"top;", @"\U000022a4" },
    { @"topbot;", @"\U00002336" },
    { @"topcir;", @"\U00002af1" },
    { @"topf;", @"\U0001d565" },
    { @"topfork;", @"\U00002ada" },
    { @"tosa;", @"\U00002929" },
    { @"tprime;", @"\U00002034" },
    { @"trade;", @"\U00002122" },
    { @"triangle;", @"\U000025b5" },
    { @"triangledown;", @"\U000025bf" },
    { @"triangleleft;", @"\U000025c3" },
    { @"trianglelefteq;", @"\U000022b4" },
    { @"triangleq;", @"\U0000225c" },
    { @"triangleright;", @"\U000025b9" },
    { @"trianglerighteq;", @"\U000022b5" },
    { @"tridot;", @"\U000025ec" },
    { @"trie;", @"\U0000225c" },
    { @"triminus;", @"\U00002a3a" },
    { @"triplus;", @"\U00002a39" },
    { @"trisb;", @"\U000029cd" },
    { @"tritime;", @"\U00002a3b" },
    { @"trpezium;", @"\U000023e2" },
    { @"tscr;", @"\U0001d4c9" },
    { @"tscy;", @"\U00000446" },
    { @"tshcy;", @"\U0000045b" },
    { @"tstrok;", @"\U00000167" },
    { @"twixt;", @"\U0000226c" },
    { @"twoheadleftarrow;", @"\U0000219e" },
    { @"twoheadrightarrow;", @"\U000021a0" },
    { @"uArr;", @"\U000021d1" },
    { @"uHar;", @"\U00002963" },
    { @"uacute;", @"\U000000fa" },
    { @"uarr;", @"\U00002191" },
    { @"ubrcy;", @"\U0000045e" },
    { @"ubreve;", @"\U0000016d" },
    { @"ucirc;", @"\U000000fb" },
    { @"ucy;", @"\U00000443" },
    { @"udarr;", @"\U000021c5" },
    { @"udblac;", @"\U00000171" },
    { @"udhar;", @"\U0000296e" },
    { @"ufisht;", @"\U0000297e" },
    { @"ufr;", @"\U0001d532" },
    { @"ugrave;", @"\U000000f9" },
    { @"uharl;", @"\U000021bf" },
    { @"uharr;", @"\U000021be" },
    { @"uhblk;", @"\U00002580" },
    { @"ulcorn;", @"\U0000231c" },
    { @"ulcorner;", @"\U0000231c" },
    { @"ulcrop;", @"\U0000230f" },
    { @"ultri;", @"\U000025f8" },
    { @"umacr;", @"\U0000016b" },
    { @"uml;", @"\U000000a8" },
    { @"uogon;", @"\U00000173" },
    { @"uopf;", @"\U0001d566" },
    { @"uparrow;", @"\U00002191" },
    { @"updownarrow;", @"\U00002195" },
    { @"upharpoonleft;", @"\U000021bf" },
    { @"upharpoonright;", @"\U000021be" },
    { @"uplus;", @"\U0000228e" },
    { @"upsi;", @"\U000003c5" },
    { @"upsih;", @"\U000003d2" },
    { @"upsilon;", @"\U000003c5" },
    { @"upuparrows;", @"\U000021c8" },
    { @"urcorn;", @"\U0000231d" },
    { @"urcorner;", @"\U0000231d" },
    { @"urcrop;", @"\U0000230e" },
    { @"uring;", @"\U0000016f" },
    { @"urtri;", @"\U000025f9" },
    { @"uscr;", @"\U0001d4ca" },
    { @"utdot;", @"\U000022f0" },
    { @"utilde;", @"\U00000169" },
    { @"utri;", @"\U000025b5" },
    { @"utrif;", @"\U000025b4" },
    { @"uuarr;", @"\U000021c8" },
    { @"uuml;", @"\U000000fc" },
    { @"uwangle;", @"\U000029a7" },
    { @"vArr;", @"\U000021d5" },
    { @"vBar;", @"\U00002ae8" },
    { @"vBarv;", @"\U00002ae9" },
    { @"vDash;", @"\U000022a8" },
    { @"vangrt;", @"\U0000299c" },
    { @"varepsilon;", @"\U000003f5" },
    { @"varkappa;", @"\U000003f0" },
    { @"varnothing;", @"\U00002205" },
    { @"varphi;", @"\U000003d5" },
    { @"varpi;", @"\U000003d6" },
    { @"varpropto;", @"\U0000221d" },
    { @"varr;", @"\U00002195" },
    { @"varrho;", @"\U000003f1" },
    { @"varsigma;", @"\U000003c2" },
    { @"varsubsetneq;", @"\U0000228a\U0000fe00" },
    { @"varsubsetneqq;", @"\U00002acb\U0000fe00" },
    { @"varsupsetneq;", @"\U0000228b\U0000fe00" },
    { @"varsupsetneqq;", @"\U00002acc\U0000fe00" },
    { @"vartheta;", @"\U000003d1" },
    { @"vartriangleleft;", @"\U000022b2" },
    { @"vartriangleright;", @"\U000022b3" },
    { @"vcy;", @"\U00000432" },
    { @"vdash;", @"\U000022a2" },
    { @"vee;", @"\U00002228" },
    { @"veebar;", @"\U000022bb" },
    { @"veeeq;", @"\U0000225a" },
    { @"vellip;", @"\U000022ee" },
    { @"verbar;", @"|" },
    { @"vert;", @"|" },
    { @"vfr;", @"\U0001d533" },
    { @"vltri;", @"\U000022b2" },
    { @"vnsub;", @"\U00002282\U000020d2" },
    { @"vnsup;", @"\U00002283\U000020d2" },
    { @"vopf;", @"\U0001d567" },
    { @"vprop;", @"\U0000221d" },
    { @"vrtri;", @"\U000022b3" },
    { @"vscr;", @"\U0001d4cb" },
    { @"vsubnE;", @"\U00002acb\U0000fe00" },
    { @"vsubne;", @"\U0000228a\U0000fe00" },
    { @"vsupnE;", @"\U00002acc\U0000fe00" },
    { @"vsupne;", @"\U0000228b\U0000fe00" },
    { @"vzigzag;", @"\U0000299a" },
    { @"wcirc;", @"\U00000175" },
    { @"wedbar;", @"\U00002a5f" },
    { @"wedge;", @"\U00002227" },
    { @"wedgeq;", @"\U00002259" },
    { @"weierp;", @"\U00002118" },
    { @"wfr;", @"\U0001d534" },
    { @"wopf;", @"\U0001d568" },
    { @"wp;", @"\U00002118" },
    { @"wr;", @"\U00002240" },
    { @"wreath;", @"\U00002240" },
    { @"wscr;", @"\U0001d4cc" },
    { @"xcap;", @"\U000022c2" },
    { @"xcirc;", @"\U000025ef" },
    { @"xcup;", @"\U000022c3" },
    { @"xdtri;", @"\U000025bd" },
    { @"xfr;", @"\U0001d535" },
    { @"xhArr;", @"\U000027fa" },
    { @"xharr;", @"\U000027f7" },
    { @"xi;", @"\U000003be" },
    { @"xlArr;", @"\U000027f8" },
    { @"xlarr;", @"\U000027f5" },
    { @"xmap;", @"\U000027fc" },
    { @"xnis;", @"\U000022fb" },
    { @"xodot;", @"\U00002a00" },
    { @"xopf;", @"\U0001d569" },
    { @"xoplus;", @"\U00002a01" },
    { @"xotime;", @"\U00002a02" },
    { @"xrArr;", @"\U000027f9" },
    { @"xrarr;", @"\U000027f6" },
    { @"xscr;", @"\U0001d4cd" },
    { @"xsqcup;", @"\U00002a06" },
    { @"xuplus;", @"\U00002a04" },
    { @"xutri;", @"\U000025b3" },
    { @"xvee;", @"\U000022c1" },
    { @"xwedge;", @"\U000022c0" },
    { @"yacute;", @"\U000000fd" },
    { @"yacy;", @"\U0000044f" },
    { @"ycirc;", @"\U00000177" },
    { @"ycy;", @"\U0000044b" },
    { @"yen;", @"\U000000a5" },
    { @"yfr;", @"\U0001d536" },
    { @"yicy;", @"\U00000457" },
    { @"yopf;", @"\U0001d56a" },
    { @"yscr;", @"\U0001d4ce" },
    { @"yucy;", @"\U0000044e" },
    { @"yuml;", @"\U000000ff" },
    { @"zacute;", @"\U0000017a" },
    { @"zcaron;", @"\U0000017e" },
    { @"zcy;", @"\U00000437" },
    { @"zdot;", @"\U0000017c" },
    { @"zeetrf;", @"\U00002128" },
    { @"zeta;", @"\U000003b6" },
    { @"zfr;", @"\U0001d537" },
    { @"zhcy;", @"\U00000436" },
    { @"zigrarr;", @"\U000021dd" },
    { @"zopf;", @"\U0001d56b" },
    { @"zscr;", @"\U0001d4cf" },
    { @"zwj;", @"\U0000200d" },
    { @"zwnj;", @"\U0000200c" },
};

static const NamedReferenceTable NamedSemicolonlessReferences[] = {
    { @"AElig", @"\U000000c6" },
    { @"AMP", @"&" },
    { @"Aacute", @"\U000000c1" },
    { @"Acirc", @"\U000000c2" },
    { @"Agrave", @"\U000000c0" },
    { @"Aring", @"\U000000c5" },
    { @"Atilde", @"\U000000c3" },
    { @"Auml", @"\U000000c4" },
    { @"COPY", @"\U000000a9" },
    { @"Ccedil", @"\U000000c7" },
    { @"ETH", @"\U000000d0" },
    { @"Eacute", @"\U000000c9" },
    { @"Ecirc", @"\U000000ca" },
    { @"Egrave", @"\U000000c8" },
    { @"Euml", @"\U000000cb" },
    { @"GT", @">" },
    { @"Iacute", @"\U000000cd" },
    { @"Icirc", @"\U000000ce" },
    { @"Igrave", @"\U000000cc" },
    { @"Iuml", @"\U000000cf" },
    { @"LT", @"<" },
    { @"Ntilde", @"\U000000d1" },
    { @"Oacute", @"\U000000d3" },
    { @"Ocirc", @"\U000000d4" },
    { @"Ograve", @"\U000000d2" },
    { @"Oslash", @"\U000000d8" },
    { @"Otilde", @"\U000000d5" },
    { @"Ouml", @"\U000000d6" },
    { @"QUOT", @"\"" },
    { @"REG", @"\U000000ae" },
    { @"THORN", @"\U000000de" },
    { @"Uacute", @"\U000000da" },
    { @"Ucirc", @"\U000000db" },
    { @"Ugrave", @"\U000000d9" },
    { @"Uuml", @"\U000000dc" },
    { @"Yacute", @"\U000000dd" },
    { @"aacute", @"\U000000e1" },
    { @"acirc", @"\U000000e2" },
    { @"acute", @"\U000000b4" },
    { @"aelig", @"\U000000e6" },
    { @"agrave", @"\U000000e0" },
    { @"amp", @"&" },
    { @"aring", @"\U000000e5" },
    { @"atilde", @"\U000000e3" },
    { @"auml", @"\U000000e4" },
    { @"brvbar", @"\U000000a6" },
    { @"ccedil", @"\U000000e7" },
    { @"cedil", @"\U000000b8" },
    { @"cent", @"\U000000a2" },
    { @"copy", @"\U000000a9" },
    { @"curren", @"\U000000a4" },
    { @"deg", @"\U000000b0" },
    { @"divide", @"\U000000f7" },
    { @"eacute", @"\U000000e9" },
    { @"ecirc", @"\U000000ea" },
    { @"egrave", @"\U000000e8" },
    { @"eth", @"\U000000f0" },
    { @"euml", @"\U000000eb" },
    { @"frac12", @"\U000000bd" },
    { @"frac14", @"\U000000bc" },
    { @"frac34", @"\U000000be" },
    { @"gt", @">" },
    { @"iacute", @"\U000000ed" },
    { @"icirc", @"\U000000ee" },
    { @"iexcl", @"\U000000a1" },
    { @"igrave", @"\U000000ec" },
    { @"iquest", @"\U000000bf" },
    { @"iuml", @"\U000000ef" },
    { @"laquo", @"\U000000ab" },
    { @"lt", @"<" },
    { @"macr", @"\U000000af" },
    { @"micro", @"\U000000b5" },
    { @"middot", @"\U000000b7" },
    { @"nbsp", @"\U000000a0" },
    { @"not", @"\U000000ac" },
    { @"ntilde", @"\U000000f1" },
    { @"oacute", @"\U000000f3" },
    { @"ocirc", @"\U000000f4" },
    { @"ograve", @"\U000000f2" },
    { @"ordf", @"\U000000aa" },
    { @"ordm", @"\U000000ba" },
    { @"oslash", @"\U000000f8" },
    { @"otilde", @"\U000000f5" },
    { @"ouml", @"\U000000f6" },
    { @"para", @"\U000000b6" },
    { @"plusmn", @"\U000000b1" },
    { @"pound", @"\U000000a3" },
    { @"quot", @"\"" },
    { @"raquo", @"\U000000bb" },
    { @"reg", @"\U000000ae" },
    { @"sect", @"\U000000a7" },
    { @"shy", @"\U000000ad" },
    { @"sup1", @"\U000000b9" },
    { @"sup2", @"\U000000b2" },
    { @"sup3", @"\U000000b3" },
    { @"szlig", @"\U000000df" },
    { @"thorn", @"\U000000fe" },
    { @"times", @"\U000000d7" },
    { @"uacute", @"\U000000fa" },
    { @"ucirc", @"\U000000fb" },
    { @"ugrave", @"\U000000f9" },
    { @"uml", @"\U000000a8" },
    { @"uuml", @"\U000000fc" },
    { @"yacute", @"\U000000fd" },
    { @"yen", @"\U000000a5" },
    { @"yuml", @"\U000000ff" },
};

static const NSUInteger LongestReferenceNameLength = 32;

static NamedReferenceTable * LongestNamedReferencePrefix(NSString *search)
{
    // Binary search to quickly find any prefix.
    static int (^comparator)() = ^int(const void *voidKey, const void *voidItem) {
        const NSString *key = (__bridge const NSString *)voidKey;
        const NamedReferenceTable *item = voidItem;
        if ([key hasPrefix:item->name]) {
            return 0;
        } else {
            return [key compare:item->name];
        }
    };
    void *voidSearch = (__bridge void *)search;
    NamedReferenceTable *itemWithSemicolon = bsearch_b(voidSearch, NamedReferences, sizeof(NamedReferences) / sizeof(NamedReferences[0]), sizeof(NamedReferenceTable), comparator);
    if (itemWithSemicolon) return itemWithSemicolon;
    
    // Stumble upon a semicolonless prefix; the longest prefix can't be far from there.
    size_t count = sizeof(NamedSemicolonlessReferences) / sizeof(NamedSemicolonlessReferences[0]);
    NamedReferenceTable *prefixItem = bsearch_b(voidSearch, NamedSemicolonlessReferences, count, sizeof(NamedReferenceTable), comparator);
    if (!prefixItem) return nil;
    NamedReferenceTable *longestPrefixItem = prefixItem;
    for (NamedReferenceTable *item = prefixItem - 1; item >= NamedReferences; item--) {
        if (![item->name hasPrefix:prefixItem->name]) break;
        if ([search hasPrefix:item->name] && item->name.length > longestPrefixItem->name.length) {
            longestPrefixItem = item;
        }
    }
    for (NamedReferenceTable *item = prefixItem + 1; item < NamedReferences + count; item++) {
        if (![item->name hasPrefix:prefixItem->name]) break;
        if ([search hasPrefix:item->name] && item->name.length > longestPrefixItem->name.length) {
            longestPrefixItem = item;
        }
    }
    return longestPrefixItem;
}

#pragma mark NSEnumerator

- (id)nextObject
{
    while (!_done && _tokenQueue.count == 0) {
        [self resume];
    }
    if (_tokenQueue.count == 0) return nil;
    id token = _tokenQueue[0];
    [_tokenQueue removeObjectAtIndex:0];
    return token;
}

#pragma mark NSObject

- (id)init
{
    return [self initWithString:nil];
}

@end

@implementation HTMLDOCTYPEToken
{
    NSMutableString *_name;
    NSMutableString *_publicIdentifier;
    NSMutableString *_systemIdentifier;
}

- (NSString *)name
{
    return [_name copy];
}

- (void)appendLongCharacterToName:(UTF32Char)character
{
    if (!_name) _name = [NSMutableString new];
    AppendLongCharacter(_name, character);
}

- (NSString *)publicIdentifier
{
    return [_publicIdentifier copy];
}

- (void)setPublicIdentifier:(NSString *)string
{
    _publicIdentifier = [string mutableCopy];
}

- (void)appendStringToPublicIdentifier:(NSString *)string
{
    if (string.length == 0) return;
    if (!_publicIdentifier) _publicIdentifier = [NSMutableString new];
    [_publicIdentifier appendString:string];
}

- (NSString *)systemIdentifier
{
    return [_systemIdentifier copy];
}

- (void)setSystemIdentifier:(NSString *)string
{
    _systemIdentifier = [string mutableCopy];
}

- (void)appendStringToSystemIdentifier:(NSString *)string
{
    if (string.length == 0) return;
    if (!_systemIdentifier) _systemIdentifier = [NSMutableString new];
    [_systemIdentifier appendString:string];
}

#pragma mark NSObject

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p <!DOCTYPE %@ %@ %@> >", self.class, self, self.name,
            self.publicIdentifier, self.systemIdentifier];
}

- (BOOL)isEqual:(HTMLDOCTYPEToken *)other
{
    #define AreNilOrEqual(a, b) ([(a) isEqual:(b)] || ((a) == nil && (b) == nil))
    return ([other isKindOfClass:[HTMLDOCTYPEToken class]] &&
            AreNilOrEqual(other.name, self.name) &&
            AreNilOrEqual(other.publicIdentifier, self.publicIdentifier) &&
            AreNilOrEqual(other.systemIdentifier, self.systemIdentifier));
}

@end

@implementation HTMLTagToken
{
    NSMutableString *_tagName;
    BOOL _selfClosingFlag;
}

- (id)init
{
    self = [super init];
    if (!self) return nil;
    
    _tagName = [NSMutableString new];
    _attributes = [HTMLOrderedDictionary new];
    
    return self;
}

- (id)initWithTagName:(NSString *)tagName
{
    self = [self init];
    if (!self) return nil;
    
    [_tagName setString:tagName];
    
    return self;
}

- (NSString *)tagName
{
    return [_tagName copy];
}

- (void)setTagName:(NSString *)tagName
{
    [_tagName setString:tagName];
}

- (BOOL)selfClosingFlag
{
    return _selfClosingFlag;
}

- (void)setSelfClosingFlag:(BOOL)flag
{
    _selfClosingFlag = flag;
}

- (void)appendLongCharacterToTagName:(UTF32Char)character
{
    AppendLongCharacter(_tagName, character);
}

#pragma mark NSObject

- (BOOL)isEqual:(HTMLTagToken *)other
{
    return ([other isKindOfClass:[HTMLTagToken class]] &&
            [other.tagName isEqualToString:self.tagName] &&
            other.selfClosingFlag == self.selfClosingFlag &&
            AreNilOrEqual(other.attributes, self.attributes));
}

- (NSUInteger)hash
{
    return self.tagName.hash + self.attributes.hash;
}

@end

@implementation HTMLStartTagToken

- (id)copyWithTagName:(NSString *)tagName
{
    HTMLStartTagToken *copy = [[self.class alloc] initWithTagName:tagName];
    copy.attributes = self.attributes;
    copy.selfClosingFlag = self.selfClosingFlag;
    return copy;
}

#pragma mark NSObject

- (NSString *)description
{
    NSMutableString *attributeDescription = [NSMutableString new];
    [self.attributes enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [attributeDescription appendFormat:@" %@=\"%@\"", name, value];
    }];
    return [NSString stringWithFormat:@"<%@: %p <%@%@> >", self.class, self, self.tagName, attributeDescription];
}

- (BOOL)isEqual:(HTMLStartTagToken *)other
{
    return ([super isEqual:other] && [other isKindOfClass:[HTMLStartTagToken class]]);
}

@end

@implementation HTMLEndTagToken

#pragma mark NSObject

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p </%@> >", self.class, self, self.tagName];
}

- (BOOL)isEqual:(HTMLEndTagToken *)other
{
    return ([other isKindOfClass:[HTMLEndTagToken class]] &&
            [other.tagName isEqualToString:self.tagName]);
}

@end

@implementation HTMLCommentToken
{
    NSMutableString *_data;
}

- (id)initWithData:(NSString *)data
{
    if (!(self = [super init])) return nil;
    _data = [NSMutableString stringWithString:(data ?: @"")];
    return self;
}

- (id)init
{
    return [self initWithData:nil];
}

- (NSString *)data
{
    return _data;
}

- (void)appendFormat:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    [_data appendString:[[NSString alloc] initWithFormat:format arguments:args]];
    va_end(args);
}

- (void)appendString:(NSString *)string
{
    if (string.length == 0) return;
    [_data appendString:string];
}

- (void)appendLongCharacter:(UTF32Char)character
{
    AppendLongCharacter(_data, character);
}

#pragma mark NSObject

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p <!-- %@ --> >", self.class, self, self.data];
}

- (BOOL)isEqual:(HTMLCommentToken *)other
{
    return ([other isKindOfClass:[HTMLCommentToken class]] &&
            [other.data isEqualToString:self.data]);
}

- (NSUInteger)hash
{
    return self.data.hash;
}

@end

@implementation HTMLCharacterToken

- (id)initWithString:(NSString *)string
{
    if (!(self = [super init])) return nil;
    _string = [string copy];
    return self;
}

- (instancetype)leadingWhitespaceToken
{
    CFRange range = CFRangeMake(0, self.string.length);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer((__bridge CFStringRef)self.string, &buffer, range);
    for (CFIndex i = 0; i < range.length; i++) {
        if (!is_whitespace(CFStringGetCharacterFromInlineBuffer(&buffer, i))) {
            NSString *leadingWhitespace = [self.string substringToIndex:i];
            if (leadingWhitespace.length > 0) {
                return [[[self class] alloc] initWithString:leadingWhitespace];
            } else {
                return nil;
            }
        }
    }
    return self;
}

- (instancetype)afterLeadingWhitespaceToken
{
    CFRange range = CFRangeMake(0, self.string.length);
    CFStringInlineBuffer buffer;
    CFStringInitInlineBuffer((__bridge CFStringRef)self.string, &buffer, range);
    for (CFIndex i = 0; i < range.length; i++) {
        if (!is_whitespace(CFStringGetCharacterFromInlineBuffer(&buffer, i))) {
            NSString *afterLeadingWhitespace = [self.string substringFromIndex:i];
            return [[[self class] alloc] initWithString:afterLeadingWhitespace];
        }
    }
    return nil;
}

#pragma mark NSObject

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p '%@'>", self.class, self, self.string];
}

- (BOOL)isEqual:(HTMLCharacterToken *)other
{
    return [other isKindOfClass:[HTMLCharacterToken class]] && [other.string isEqualToString:self.string];
}

- (NSUInteger)hash
{
    return self.string.hash;
}

@end

@implementation HTMLParseErrorToken

- (id)initWithError:(NSString *)error
{
    if (!(self = [super init])) return nil;
    _error = [error copy];
    return self;
}

- (id)init
{
    return [self initWithError:nil];
}

#pragma mark NSObject

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[HTMLParseErrorToken class]];
}

- (NSUInteger)hash
{
    // Must be constant since all parse errors are equivalent.
    return 27;
}

@end

@implementation HTMLEOFToken

#pragma mark NSObject

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[HTMLEOFToken class]];
}

- (NSUInteger)hash
{
    // Random constant.
    return 1245524566;
}

@end
