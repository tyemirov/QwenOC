# Security

QwenOC keeps inference on the Mac. It connects to the local LM Studio API at `http://127.0.0.1:1234`. OpenCode keeps sessions local. For Splash, see [Splash install and validation](docs/splash.md).

Context7 and `gh_grep` make network requests when used. The Bureaucrat connects to Google with the scopes in the contract. See [Bureaucrat install](docs/bureaucrat-setup.md) for the scope contract.

The launcher uses the open Chrome session for the Bureaucrat. That session gives the agent access to its data, local storage, and the accounts in the session. Use this only for an agent that you control.

The OAuth token files for Gmail and Drive stay local. Keep these files and the desktop key safe. The repository ignore file keeps their standard filenames out of Git.

## Report a security problem

Send security reports to [support@mprlab.com](mailto:support@mprlab.com). Do not open an issue for a security problem.

Give the component, the problem, and the steps that show the problem. Remove credentials, OAuth tokens, and account data from reports and logs before you send them.
