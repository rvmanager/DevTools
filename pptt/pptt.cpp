#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <set>
#include <sstream>
#include <unistd.h> // for getopt

namespace fs = std::filesystem;

class TreePrinter {
private:
    std::set<std::string> exclude_list;
    bool show_dir_only = false;
    
    bool is_excluded(const std::string& name) const {
        return exclude_list.find(name) != exclude_list.end();
    }
    
    bool is_binary(const fs::path& file_path) const {
        std::ifstream file(file_path, std::ios::binary);
        if (!file.is_open()) {
            return true; // Assume binary if can't open
        }
        
        // Read first 512 bytes to check for binary content
        char buffer[512];
        file.read(buffer, sizeof(buffer));
        std::streamsize bytes_read = file.gcount();
        
        // Check for null bytes (common indicator of binary files)
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            if (buffer[i] == '\0') {
                return true;
            }
        }
        
        // Check for high ratio of non-printable characters
        int non_printable = 0;
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            unsigned char c = static_cast<unsigned char>(buffer[i]);
            if (c < 32 && c != '\t' && c != '\n' && c != '\r') {
                non_printable++;
            }
        }
        
        // If more than 30% non-printable, consider it binary
        return (bytes_read > 0) && (non_printable * 100 / bytes_read > 30);
    }
    
    void print_tree(const fs::path& dir, const std::string& prefix) const {
        if (!fs::exists(dir) || !fs::is_directory(dir)) {
            return;
        }
        
        std::vector<fs::directory_entry> entries;
        
        // Collect all entries
        try {
            for (const auto& entry : fs::directory_iterator(dir)) {
                // Skip hidden files (starting with .)
                std::string filename = entry.path().filename().string();
                if (filename[0] != '.' && !is_excluded(filename)) {
                    entries.push_back(entry);
                }
            }
        } catch (const fs::filesystem_error& e) {
            std::cerr << "Error reading directory " << dir << ": " << e.what() << std::endl;
            return;
        }
        
        // Sort entries
        std::sort(entries.begin(), entries.end(), 
                  [](const fs::directory_entry& a, const fs::directory_entry& b) {
                      return a.path().filename() < b.path().filename();
                  });
        
        // Print entries
        for (const auto& entry : entries) {
            std::string filename = entry.path().filename().string();
            std::cout << prefix << "|_ " << filename << std::endl;
            
            if (entry.is_directory()) {
                print_tree(entry.path(), prefix + "|     ");
            }
        }
    }
    
    void print_file_content(const fs::path& dir, const std::string& root_name) const {
        if (!fs::exists(dir)) {
            return;
        }
        
        std::vector<fs::path> files;
        
        // Collect all files recursively
        try {
            for (const auto& entry : fs::recursive_directory_iterator(dir)) {
                if (entry.is_regular_file()) {
                    std::string filename = entry.path().filename().string();
                    // Skip hidden files and excluded files
                    if (filename[0] != '.' && !is_excluded(filename)) {
                        files.push_back(entry.path());
                    }
                }
            }
        } catch (const fs::filesystem_error& e) {
            std::cerr << "Error reading directory " << dir << ": " << e.what() << std::endl;
            return;
        }
        
        // Sort files
        std::sort(files.begin(), files.end());
        
        // Print file contents
        for (const auto& file_path : files) {
            if (!is_binary(file_path)) {
                fs::path relative_path = fs::relative(file_path, dir);
                
                std::cout << std::endl;
                std::cout << "===================================" << std::endl;
                std::cout << "File: " << root_name << "/" << relative_path.string() << std::endl;
                std::cout << "<content> -------------------------" << std::endl;
                
                std::ifstream file(file_path);
                if (file.is_open()) {
                    std::cout << file.rdbuf();
                    file.close();
                } else {
                    std::cout << "Error: Could not open file" << std::endl;
                }
                
                std::cout << "</content> ------------------------" << std::endl;
                std::cout << std::endl;
            }
        }
    }
    
    void print_single_file(const fs::path& file_path) const {
        if (!fs::exists(file_path) || !fs::is_regular_file(file_path)) {
            std::cout << "Error: File does not exist or is not a regular file." << std::endl;
            return;
        }
        
        if (is_binary(file_path)) {
            std::cout << "The file " << file_path << " is binary. Content not displayed." << std::endl;
            return;
        }
        
        fs::path parent_dir = file_path.parent_path();
        std::string root_name = parent_dir.filename().string();
        std::string file_name = file_path.filename().string();
        
        std::cout << "===================================" << std::endl;
        std::cout << "File: " << root_name << "/" << file_name << std::endl;
        std::cout << "<content> -------------------------" << std::endl;
        
        std::ifstream file(file_path);
        if (file.is_open()) {
            std::cout << file.rdbuf();
            file.close();
        } else {
            std::cout << "Error: Could not open file" << std::endl;
        }
        
        std::cout << "</content> ------------------------" << std::endl;
    }
    
public:
    void set_exclude_list(const std::string& exclude_str) {
        if (exclude_str.empty()) return;
        
        std::stringstream ss(exclude_str);
        std::string item;
        
        while (std::getline(ss, item, ',')) {
            // Trim whitespace
            item.erase(0, item.find_first_not_of(" \t"));
            item.erase(item.find_last_not_of(" \t") + 1);
            if (!item.empty()) {
                exclude_list.insert(item);
            }
        }
    }
    
    void set_show_dir_only(bool value) {
        show_dir_only = value;
    }
    
    void process_target(const std::string& target) {
        if (target.empty()) {
            // Current directory
            fs::path current_dir = fs::current_path();
            std::string root_name = current_dir.filename().string();
            
            std::cout << root_name << std::endl;
            print_tree(current_dir, "");
            
            if (!show_dir_only) {
                print_file_content(current_dir, root_name);
            }
        } else {
            fs::path target_path(target);
            
            if (fs::is_directory(target_path)) {
                std::string root_name = fs::absolute(target_path).filename().string();
                
                std::cout << root_name << std::endl;
                print_tree(target_path, "");
                
                if (!show_dir_only) {
                    print_file_content(target_path, root_name);
                }
            } else if (fs::is_regular_file(target_path)) {
                print_single_file(target_path);
            } else {
                std::cout << "Error: Target does not exist or is not accessible." << std::endl;
            }
        }
    }
    
    static void print_usage(const char* program_name) {
        std::cout << "Usage: " << program_name << " [-d] [-x exclude_list] [filename|directory]" << std::endl;
        std::cout << "  -d : only show the directory structure" << std::endl;
        std::cout << "  -x exclude_list : comma-separated list of files and directories to exclude" << std::endl;
        std::cout << "  filename or directory : show output from given directory, or if a file, only the file content" << std::endl;
        std::cout << "  If no arguments are provided, it will show both structure and content for the current directory" << std::endl;
    }
};

int main(int argc, char* argv[]) {
    TreePrinter printer;
    std::string target;
    
    int opt;
    while ((opt = getopt(argc, argv, "dx:")) != -1) {
        switch (opt) {
            case 'd':
                printer.set_show_dir_only(true);
                break;
            case 'x':
                printer.set_exclude_list(optarg);
                break;
            default:
                TreePrinter::print_usage(argv[0]);
                return 1;
        }
    }
    
    // Get remaining argument (target)
    if (optind < argc) {
        target = argv[optind];
    }
    
    printer.process_target(target);
    
    return 0;
}
