"""The router's own internet byte counters over UPnP (no password): totals() → (received, sent). The router is found once
by SSDP and remembered in ~/.local/share/netwatch/igd.json."""
import json, os, re, socket, urllib.request

CACHE = os.path.expanduser("~/.local/share/netwatch/igd.json")
ST = "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"


def _find():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    s.sendto(b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\n'
             b'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n', ("239.255.255.250", 1900))
    d, _ = s.recvfrom(4096); loc = re.search(rb"(?i)location:\s*(\S+)", d).group(1).decode()
    x = urllib.request.urlopen(loc, timeout=5).read().decode(errors="replace")
    ctl = re.search(rf"<serviceType>{re.escape(ST)}</serviceType>.*?<controlURL>([^<]*)", x, re.S).group(1)
    p = loc.split("/", 3); url = p[0] + "//" + p[2] + ctl
    json.dump({"url": url}, open(CACHE, "w")); return url


def _call(url, act):
    body = (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:{act} xmlns:u="{ST}"/></s:Body></s:Envelope>')
    r = urllib.request.Request(url, body.encode(), {"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{ST}#{act}"'})
    return int(re.search(r"<NewTotalBytes\w+>(\d+)", urllib.request.urlopen(r, timeout=5).read().decode()).group(1))


def totals():
    try: url = json.load(open(CACHE))["url"]
    except (OSError, ValueError, KeyError): url = _find()
    try: return _call(url, "GetTotalBytesReceived"), _call(url, "GetTotalBytesSent")
    except OSError:
        url = _find(); return _call(url, "GetTotalBytesReceived"), _call(url, "GetTotalBytesSent")


if __name__ == "__main__":
    print(totals())
