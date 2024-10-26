<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
Octosail - Easy Amazon Lightsail (stop, start, or reboot)
</h2>

A simple script to manage Amazon Lightsail instances directly from your terminal. `octosail` allows you to stop, start, or reboot your Lightsail instances with ease.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Stopping an Instance](#stopping-an-instance)
  - [Starting an Instance](#starting-an-instance)
  - [Rebooting an Instance](#rebooting-an-instance)
- [Examples](#examples)
- [How It Works](#how-it-works)
- [License](#license)

## Features

- **Stop an Instance**: Gracefully stop a running Lightsail instance.
- **Start an Instance**: Start a stopped Lightsail instance.
- **Reboot an Instance**: Stop an instance, wait until it's fully stopped, pause for 1 minute, and then start it again.
- **Initial Setup Checks**: Automatically checks if AWS CLI is installed and configured, and assists in setting it up if not.

## Installation

To install `octosail`, run the following commands in your terminal:

```bash
sudo curl -L "https://git.vdm.dev/api/v1/repos/octoleo/octosail/raw/src/octosail" -o /usr/local/bin/octosail
sudo chmod +x /usr/local/bin/octosail
```

This will download the script to `/usr/local/bin/octosail` and make it executable.

## Prerequisites

- **AWS CLI**: The script requires the AWS Command Line Interface (CLI) to interact with your AWS account.
- **AWS Credentials**: You need to have your AWS credentials configured. The script will help you set this up if not already configured.

## Usage

The general syntax for using `octosail` is:

```bash
octosail --stop <instance_name>
octosail --start <instance_name>
octosail --reboot <instance_name>
```

### Stopping an Instance

To stop a running Lightsail instance:

```bash
octosail --stop MyInstanceName
```

### Starting an Instance

To start a stopped Lightsail instance:

```bash
octosail --start MyInstanceName
```

### Rebooting an Instance

To reboot a Lightsail instance:

```bash
octosail --reboot MyInstanceName
```

This command will:

1. Stop the instance.
2. Poll the instance status until it changes to `stopped`.
3. Wait for 1 minute.
4. Start the instance again.

## Examples

- **Stop an Instance Named "WebServer":**

  ```bash
  octosail --stop WebServer
  ```

- **Start an Instance Named "DatabaseServer":**

  ```bash
  octosail --start DatabaseServer
  ```

- **Reboot an Instance Named "CacheServer":**

  ```bash
  octosail --reboot CacheServer
  ```

## How It Works

When you run `octosail`, it performs the following steps:

1. **AWS CLI Installation Check:**
   - Checks if the AWS CLI is installed.
   - If not installed, prompts you to install it.
   - Supports automatic installation on Linux and macOS systems.

2. **AWS CLI Configuration Check:**
   - Verifies if the AWS CLI is configured with your AWS credentials.
   - If not configured, prompts you to run `aws configure`.

3. **Instance Operation:**
   - Depending on the command (`--stop`, `--start`, or `--reboot`), it performs the desired operation using the AWS CLI commands.
   - For `--reboot`, it ensures the instance is fully stopped before starting it again, including a 1-minute wait period.

---
# Free Software License
```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```
