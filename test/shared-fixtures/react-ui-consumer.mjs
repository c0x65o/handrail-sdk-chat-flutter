import * as React from "react";
import * as reactIntegration from "@handrail/chat/react";
import * as ui from "@handrail/chat/ui";

process.stdout.write(
  JSON.stringify({
    reactVersion: React.version,
    reactIntegrationExportNames: Object.keys(reactIntegration),
    uiExportNames: Object.keys(ui),
  }),
);
