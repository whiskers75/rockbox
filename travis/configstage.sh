while sleep 5
do printf .
done & 
export x=$! 
sudo ../travis/configure.sh > /dev/null 2>/dev/null &
wait "$!" 
kill "$x"
echo "COMPLETED"