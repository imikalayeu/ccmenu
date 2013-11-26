
#import "NSString+CCMAdditions.h"
#import "NSAlert+CCMAdditions.h"
#import "CCMHistoryDataSource.h"
#import "CCMProjectSheetController.h"
#import "CCMSyncConnection.h"
#import "CCMKeychainHelper.h"
#import "CCMPreferencesController.h"
#import "strings.h"

enum CCMButtonTag
{
    CCMButtonCancel = 0,
    CCMButtonFinish = 1,
    CCMButtonContinue = 2
};


@implementation CCMProjectSheetController

- (void)beginAddSheetForWindow:(NSWindow *)aWindow
{
    [urlComboBox setStringValue:@""];
    [serverTypeMatrix selectCellWithTag:CCMDetectServer];
    [continueButton setTag:CCMButtonContinue];
    [continueButton setTitle:SHEET_CONTINUE_BUTTON];
    [self beginSheetForWindow:aWindow contextInfo:NULL];
}

- (void)beginEditSheetWithProject:(NSDictionary *)aProject forWindow:(NSWindow *)aWindow
{
    [urlComboBox setStringValue:[aProject objectForKey:@"serverUrl"]];
    [serverTypeMatrix selectCellWithTag:CCMUseGivenURL];
    [continueButton setTag:CCMButtonFinish];
    [continueButton setTitle:SHEET_SAVE_BUTTON];
    [self beginSheetForWindow:aWindow contextInfo:aProject];
}

- (void)beginSheetForWindow:(NSWindow *)aWindow contextInfo:(void *)contextInfo
{
    [self historyURLSelected:self];
    [(CCMHistoryDataSource *)[urlComboBox dataSource] reloadData:defaultsManager];
    [urlComboBox reloadData];
    [self showTestInProgress:NO];
	[sheetTabView selectFirstTabViewItem:self];
    [NSApp beginSheet:projectSheet modalForWindow:aWindow modalDelegate:self
       didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:contextInfo];
}


- (void)historyURLSelected:(id)sender
{
    [urlComboBox selectText:self];
    NSString *user = [[urlComboBox stringValue] user];
    [authCheckBox setState:(user != nil) ? NSOnState : NSOffState];
    [self useAuthenticationChanged:self];
}

- (void)serverDetectionChanged:(id)sender
{
    [urlComboBox setStringValue:[[urlComboBox stringValue] stringByAddingSchemeIfNecessary]];
}

- (IBAction)useAuthenticationChanged:(id)sender
{
    NSString *url = [[urlComboBox stringValue] stringByAddingSchemeIfNecessary];

    if([authCheckBox state] == NSOnState)
    {
        NSString *user = [url user];
        if(user == nil)
        {
            user = [CCMKeychainHelper accountForURLString:url error:NULL];
            if(user == nil)
                return;
            url = [url stringByReplacingCredentials:user];
            [urlComboBox setStringValue:url];
        }
        [userField setStringValue:user];
        NSString *password = [CCMKeychainHelper passwordForURLString:url error:NULL];
        [passwordField setStringValue:(password != nil) ? password : @""];
    }
    else
    {
        [urlComboBox setStringValue:[url stringByReplacingCredentials:@""]];
        [userField setStringValue:@""];
        [passwordField setStringValue:@""];
    }
}

- (void)controlTextDidChange:(NSNotification *)aNotification
{
    if([aNotification object] == userField)
    {
        NSString *url = [[urlComboBox stringValue] stringByAddingSchemeIfNecessary];
        [urlComboBox setStringValue:[url stringByReplacingCredentials:[userField stringValue]]];
    }
}

- (void)continueSheet:(id)sender
{
    @try
    {
        [self showTestInProgress:YES];
        BOOL useAsGiven = [serverTypeMatrix selectedTag] == CCMUseGivenURL;
        NSString *serverUrl = useAsGiven ? [self getValidatedURL] : [self getCompletedAndValidatedURL];
        if(serverUrl == nil)
            return;
        if([sender tag] == CCMButtonFinish) // edit mode
        {
            [self closeSheet:sender];
        }
        else
        {
            CCMSyncConnection *connection = [[[CCMSyncConnection alloc] initWithURLString:serverUrl] autorelease];
            [connection setDelegate:self];
            NSArray *projectInfos = [connection retrieveServerStatus];
            [chooseProjectsViewController setContent:[self convertProjectInfos:projectInfos withServerUrl:serverUrl]];
            [chooseProjectsViewController setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
            [sheetTabView selectLastTabViewItem:self];
        }
    }
    @catch(NSException *exception)
    {
        [self showTestInProgress:NO];
        [[NSAlert alertWithText:ALERT_CONN_FAILURE_TITLE informativeText:[exception reason]] runModal];
    }
    @finally
    {
        [self showTestInProgress:NO];
    }
}

- (NSString *)getValidatedURL
{
    NSString *url = [urlComboBox stringValue];
    NSInteger statusCode = [self checkURL:url];
    if(statusCode != 200)
    {
        [self showTestInProgress:NO];
        [[NSAlert alertWithText:ALERT_CONN_FAILURE_TITLE informativeText:[NSString stringWithFormat:(statusCode == 401) ? ALERT_CONN_FAILURE_STATUS401_INFO : ALERT_CONN_FAILURE_STATUS_INFO, (int)statusCode]] runModal];
        return nil;
    }
    return url;
}

- (NSString *)getCompletedAndValidatedURL
{
    BOOL saw401 = NO;
    NSString *url = nil;
    NSString *baseURL = [urlComboBox stringValue];
    for(NSString *completedURL in [baseURL completeURLForAllServerTypes])
    {
        [urlComboBox setStringValue:completedURL];
        [urlComboBox display];
        NSInteger status = [self checkURL:completedURL];
        if(status == 200)
        {
            url = completedURL;
            break;
        }
        else if(status == 401)
        {
            saw401 = YES;
        }
    }
    if(url == nil)
    {
        [urlComboBox setStringValue:baseURL];
        [urlComboBox display];
        [self showTestInProgress:NO];
        [[NSAlert alertWithText:ALERT_SERVER_DETECT_FAILURE_TITLE informativeText:saw401 ? ALERT_CONN_FAILURE_STATUS401_INFO : ALERT_SERVER_DETECT_FAILURE_INFO] runModal];
        return nil;
    }
    return url;
}

- (NSInteger)checkURL:(NSString *)url
{
    CCMSyncConnection *connection = [[[CCMSyncConnection alloc] initWithURLString:url] autorelease];
    if([authCheckBox state] == NSOnState)
    {
        NSURLCredential *credential = [NSURLCredential credentialWithUser:[userField stringValue] password:[passwordField stringValue] persistence:NSURLCredentialPersistenceNone];
        [connection setCredential:credential];
    }
    NSInteger statusCode = [connection testConnection];
    if((statusCode == 200) && ([connection credential] != nil))
    {
        [CCMKeychainHelper setPassword:[[connection credential] password] forURLString:url error:NULL];
    }
    return statusCode;
}

- (void)showTestInProgress:(BOOL)flag
{
    if(flag)
    {
		[progressIndicator startAnimation:self];
        [statusField setStringValue:STATUS_TESTING];
    }
    else
    {
        [progressIndicator stopAnimation:self];
        [statusField setStringValue:@""];
    }
}

- (NSArray *)convertProjectInfos:(NSArray *)projectInfos withServerUrl:(NSString *)serverUrl
{
	NSMutableArray *result = [NSMutableArray array];
	for(NSDictionary *projectInfo in projectInfos)
	{
		NSMutableDictionary *listEntry = [NSMutableDictionary dictionary];
		NSString *projectName = [projectInfo objectForKey:@"name"];
		[listEntry setObject:projectName forKey:@"name"];
		[listEntry setObject:serverUrl forKey:@"server"];
		if([defaultsManager projectListContainsProject:projectName onServerWithURL:serverUrl])
			[listEntry setObject:[NSColor disabledControlTextColor] forKey:@"textColor"];
		[result addObject:listEntry];
	}
	return result;
}


- (void)closeSheet:(id)sender
{
    [NSApp endSheet:projectSheet returnCode:[sender tag]];
}


- (void)sheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	[projectSheet orderOut:self];
	if(returnCode == CCMButtonCancel)
		return;

    if(contextInfo == NULL)
    {
        for(NSDictionary *entry in [chooseProjectsViewController selectedObjects])
        {
            NSString *serverUrl = [entry objectForKey:@"server"];
            [defaultsManager addProject:[entry objectForKey:@"name"] onServerWithURL:serverUrl];
            [defaultsManager addServerURLToHistory:serverUrl];
        }
    }
    else
    {
        NSString *projectName = [(NSDictionary *)contextInfo objectForKey:@"projectName"];
        NSString *serverUrl = [urlComboBox stringValue];
        // Maybe we shouldn't use the allProjectsViewController here. But it makes it so much easier.
        [allProjectsViewController remove:self];
        [defaultsManager addProject:projectName onServerWithURL:serverUrl];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:CCMPreferencesChangedNotification object:self];
}

@end
