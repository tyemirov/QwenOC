# Bureaucrat install

Do the Chrome session steps and the Google Workspace authorization before the first start of Qwen The Bureaucrat.

## Chrome session

Start Chrome in the usual way. Do not add start parameters to Chrome.

1. Use Chrome 144 or a newer release.
2. In the open Chrome session, open `chrome://inspect/#remote-debugging` and turn on **Remote Debugging**.
3. Start Bureaucrat. When Chrome tells you about the debugging connection, click **Allow**.

The launcher checks the Chrome release, the active process, and the remote-debugging marker before it loads the model. The open Chrome session gives the agent access to its data, local storage, and the accounts in the session. Use this only for an agent that you control.

## Google Workspace authorization

Bureaucrat uses a local **Desktop OAuth 2.0 Client ID**. Google puts the `gmail.modify` and full-Drive scopes in the **Restricted** group. It puts the Docs and Sheets scopes in the **Sensitive** group. The `gcloud` CLI is optional. The [Google Cloud Console](https://console.cloud.google.com/) gives all the installation controls.

1. **Set up one Google Cloud project**:
   - Make or select a project in the [Google Cloud Console](https://console.cloud.google.com/).
   - Under **APIs & Services > Library**, turn on the **Gmail API**, **Google Drive API**, **Google Sheets API**, and **Google Docs API**.
   - In **Google Auth Platform > Branding**, type a name such as `Bureaucrat`, a support email address, and a contact email address.
   - In **Audience**, select **Internal** if the Google Cloud project is in your Google Workspace organization. For other Google accounts, select **External**.
   - For an External project in **Testing**, add every Google account that will authorize Bureaucrat under **Test users**.
   - In **Data Access**, add these Workspace data scopes:
     - `https://www.googleapis.com/auth/gmail.modify`
     - `https://www.googleapis.com/auth/drive`
     - `https://www.googleapis.com/auth/documents`
     - `https://www.googleapis.com/auth/spreadsheets`
   - The Drive MCP also uses the standard `openid` and `userinfo.email` scopes to identify the accounts.

2. **Get the desktop key**:
   - Open **APIs & Services > Credentials**, select **Create credentials > OAuth client ID**, and select **Desktop app**.
   - Get the JSON file. Keep the `client_secret_*.json` file in `~/Downloads`, or keep it as `~/.gmail-mcp/gcp-oauth.keys.json`.
   - Each person must make a desktop key for their account. The launcher copies keys only between the 2 local MCP locations. It never copies a key into this repository.

3. **Do the 2 authorization flows**:
   - Start `./launch-bureaucrat.command`.
   - The launcher validates the desktop key and copies it to the 2 MCP locations. It then opens the Gmail authorization flow and the Google Drive authorization flow.
   - Accept the 2 flows. Gmail keeps its OAuth token in `~/.gmail-mcp/credentials.json`. Drive, Docs, and Sheets keep their OAuth token in `~/.config/google-drive-mcp/tokens.json`.
   - The 2 OAuth token files stay local. Keep the key and the OAuth token files safe. The repository ignore file keeps their standard filenames out of Git. That is one more protection.

4. **Verify the accounts**:
   - In Bureaucrat, start `/connect` to examine the Drive accounts and select the account in use.
   - Verify Gmail with a safe read request, such as a count of new emails. The Drive check does not show Gmail access.

## Reauthorization

For an External project in **Testing**, Google [stops each test account authorization after 7 days](https://support.google.com/cloud/answer/15549945). The MCP servers get new OAuth tokens without a person step while the authorization stays active. If an authorization is lost or stopped, or if the scopes change, do a new authorization flow.

Reauthorize the 2 MCPs, or one of them, without a model start. Drive reauthorization works for every account that its MCP keeps:

```bash
./launch-bureaucrat.command --reauthorize
./launch-bureaucrat.command --reauthorize gmail
./launch-bureaucrat.command --reauthorize drive
```

If you change the External project to **In production**, Google removes the 7-day Testing limit. Google can make a scope check necessary. On the usual start, the launcher compares every kept grant against the correct scope contract. If a grant is wider than the contract, or if it is missing a scope, the launcher starts a new authorization flow.
