# 7. Printing

ICA Viewer can bring print jobs from Windows to your Mac. The session prints to a virtual PDF printer, called **Citrix PDF Printer**; ICA Viewer receives the PDF and lets you print it on your Mac.

## Turn it on

Printing is **off by default**. In **Settings > Devices** ([Settings](12-settings.md#printing)):

1. Tick **Receive print jobs**.
2. Choose what happens when a job arrives: **Show the print dialog first** (the macOS print panel) or **Open in Preview first**.

The change applies from the next time you connect.

## Print

1. In the remote app, choose **File > Print** and pick **Citrix PDF Printer** (it may be named "from" and your Mac's name).
2. A window **Print job from** *app name* shows the number of pages.
3. Click **Print…** to choose a Mac printer in the macOS print panel, **Open in Preview** to read or save the PDF first, or **Discard** to throw it away.

If several jobs arrive, the window shows how many are waiting.

## Notes

- The printers of your Mac are not listed in Windows. You print to the PDF printer, and your Mac prints the PDF.
- Whether the server offers the PDF printer depends on its policy. If printing is blocked, the [Connection Center](10-connection-center.md#features-the-server-refuses) shows "Printing: blocked by server policy".
- The lab server used for this manual does not offer the PDF printer by default, so there is no screenshot of a print job.
