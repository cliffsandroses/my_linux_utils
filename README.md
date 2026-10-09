Two setup scripts, both kept:

- `Linux_SetupScript.sh` — the current one (September 2026): flags, helpers, drivers, hardening.
- `Linux_SetupScript.overhaul.sh` — the February 2026 overhaul: menus, distro/CPU/VM detection, Docker, Bluetooth.

Rebuilding a whole machine? Start with RESTORE.md.

Notes: 

Need to have dos2unix package before using the file
or unix will assume there is a character "/r" at the end of each readout


Stackoverflow: 
"Bash expects that end-of-line in a script is always and only a newline (\n) character, Unix-style, not a carriage return-newline combination (\r\n) like you normally see on Windows. 
Bash thinks the \r character is just an ordinary character at the end of the string. (Characters that follow a double quoted string are just concatenated onto the end.)
As Ignacio suggests, the solution is to fix your script to eliminate the \r characters. dos2unix is one way. Another would be to use tr -d '\r' < infile > outfile as a filter."
