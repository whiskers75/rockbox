while sleep 5
do printf .
done & 
export 1=$! 
sudo travis/installdeps.sh > /dev/null 2>/dev/null &
wait "$!" 
kill "$1"
echo "COMPLETED"