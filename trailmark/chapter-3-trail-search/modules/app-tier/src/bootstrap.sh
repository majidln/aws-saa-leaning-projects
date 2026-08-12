#!/bin/bash
set -euo pipefail

# Amazon Linux 2 Node.js installation
amazon-linux-extras install -y nodejs

# Create a dedicated application directory
mkdir -p /opt/trailmark

# Minimal HTTP application
cat > /opt/trailmark/server.js <<'EOF'
const http = require("http");

const port = process.env.PORT || ${port};

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("Hello World\n");
    return;
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not Found\n");
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Trailmark app listening on port $${port}`);
});
EOF

# Run it as a service so it stays running after user-data finishes.
cat > /etc/systemd/system/trailmark.service <<'EOF'
[Unit]
Description=Trailmark Hello World application
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/trailmark
Environment=PORT=${port}
ExecStart=/usr/bin/node /opt/trailmark/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trailmark.service