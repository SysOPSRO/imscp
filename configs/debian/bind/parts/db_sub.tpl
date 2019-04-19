; subdomain [{SUBDOMAIN_NAME}] records BEGIN
$ORIGIN {SUBDOMAIN_NAME}.
; subdomain MAIL records BEGIN
@	IN	MX	10 mail
@	IN	TXT	"v=spf1 include:{DOMAIN_NAME} -all"
mail	IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
imap	IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
pop		IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
pop3	IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
relay	IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
smtp	IN	{BASE_SERVER_IP_TYPE}	{BASE_SERVER_IP}
; subdomain MAIL records ENDING
@	IN	{IP_TYPE}	{DOMAIN_IP}
; subdomain OPTIONAL records BEGIN
www	IN	CNAME	@
ftp	IN	{IP_TYPE}	{DOMAIN_IP}
; subdomain OPTIONAL records ENDING
; subdomain [{SUBDOMAIN_NAME}] records ENDING
