# Guide: Nginx Proxy Manager Setup

**Version: 6.0**

This guide provides the step-by-step instructions for configuring Nginx Proxy Manager (NPM) after the initial deployment.

---

### Step 1: Log In

1.  Navigate to `http://<your_vps_ip>:81`.
2.  Log in with the default credentials:
    -   **Email:** `admin@example.com`
    -   **Password:** `changeme`
3.  You will be prompted to change your username and password immediately.

### Step 2: Create the Proxy Host

1.  Go to **Hosts > Proxy Hosts**.
2.  Click **Add Proxy Host**.
3.  On the **Details** tab, enter the following:
    -   **Domain Names:** `rmmx.xinle.biz`
    -   **Scheme:** `http`
    -   **Forward Hostname / IP:** `localhost`
    -   **Forward Port:** `80` (This is just a placeholder; the locations will handle the actual routing)
    -   **Enable** `Block Common Exploits`.

### Step 3: Configure SSL

1.  Go to the **SSL** tab.
2.  In the SSL Certificate dropdown, select **Request a new SSL Certificate**.
3.  Enable **Force SSL** and **HTTP/2 Support**.
4.  Agree to the Let's Encrypt Terms of Service.
5.  Click **Save**.

NPM will now obtain an SSL certificate for `rmmx.xinle.biz`. This may take a minute.

### Step 4: Configure Locations (The Most Important Step)

This is where you tell NPM how to route traffic for each subpath (`/n8n`, `/git`, etc.) to the correct Docker container.

1.  **Edit** the `rmmx.xinle.biz` proxy host you just created.
2.  Go to the **Locations** tab.
3.  Click **Add Location** and create an entry for each service as defined in the table below. For each location, you will enter the **Location**, **Forward Hostname / IP**, **Forward Port**, and paste the contents of the corresponding `.conf` file into the **Custom Nginx Configuration** box.

| Location | Forward Hostname / IP | Forward Port | Custom Nginx Config File |
| :--- | :--- | :--- | :--- |
| `/home` | `landing` | `80` | (none) |
| `/rmm` | `netlockrmm-web` | `80` | (none) |
| `/npm` | `localhost` | `81` | `npm_admin.conf` |
| `/n8n` | `n8n` | `5678` | `n8n.conf` |
| `/git` | `forgejo` | `3000` | (none) |
| `/pgdba` | `pgadmin` | `80` | `pgadmin.conf` |
| `/dba` | `phpmyadmin` | `80` | `phpmyadmin.conf` |

### Step 5: Configure Root Redirect

Finally, you need to redirect users who visit `https://rmmx.xinle.biz/` to the landing page at `https://rmmx.xinle.biz/dash/index.html`.

1.  **Edit** the `rmmx.xinle.biz` proxy host again.
2.  Go to the **Advanced** tab.
3.  Paste the contents of the `root_redirect.conf` file into the text box.
4.  Click **Save**.

---

**Your setup is now complete.** All services should be accessible at their respective URLs with valid SSL certificates.
