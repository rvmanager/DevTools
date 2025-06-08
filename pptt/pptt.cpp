#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <algorithm>
#include <set>
#include <map>
#include <sstream>
#include <cctype>
#include <regex>
#include <unistd.h> // for getopt

namespace fs = std::filesystem;

struct PatternFilter {
    std::string pattern;
    bool is_include; // true for -e, false for -v
};

struct CommentStyle {
    std::string single_line;
    std::string multi_start;
    std::string multi_end;
    bool has_comments;
};

class TreePrinter {
private:
    std::vector<PatternFilter> pattern_filters;
    bool show_dir_only = false;
    mutable std::set<std::string> unknown_extensions; // Track unknown extensions
    
    // Comment styles lookup table
    std::map<std::string, CommentStyle> comment_styles = {
        {".cpp", {"//", "/*", "*/", true}},
        {".c", {"//", "/*", "*/", true}},
        {".h", {"//", "/*", "*/", true}},
        {".hpp", {"//", "/*", "*/", true}},
        {".swift", {"//", "/*", "*/", true}},
        {".sh", {"#", "", "", true}},
        {".bash", {"#", "", "", true}},
        {".py", {"#", "'''", "'''", true}},
        {".js", {"//", "/*", "*/", true}},
        {".ts", {"//", "/*", "*/", true}},
        {".java", {"//", "/*", "*/", true}},
        {".cs", {"//", "/*", "*/", true}},
        {".go", {"//", "/*", "*/", true}},
        {".php", {"//", "/*", "*/", true}},
        {".rb", {"#", "=begin", "=end", true}},
        {".rs", {"//", "/*", "*/", true}},
        {".lua", {"--", "--[[", "]]", true}},
        {".html", {"", "<!--", "-->", true}},
        {".xml", {"", "<!--", "-->", true}},
        {".yaml", {"#", "", "", true}},
        {".yml", {"#", "", "", true}},
        {".json", {"", "", "", false}},
        {".ini", {"#", "", "", true}},
        {".sql", {"--", "/*", "*/", true}},
        {".tex", {"%", "", "", true}},
        {".md", {"", "", "", false}},
        {".cmake", {"#", "", "", true}},
        {".txt", {"", "", "", false}},
        {".proto", {"//", "/*", "*/", true}}
    };
    
    bool matches_patterns(const std::string& name) const {
        if (pattern_filters.empty()) {
            return true; // No filters means include everything
        }
        
        bool result = true; // Start with include by default
        
        // Apply filters in order
        for (const auto& filter : pattern_filters) {
            try {
                std::regex pattern_regex(filter.pattern);
                bool matches = std::regex_search(name, pattern_regex);
                
                if (filter.is_include) {
                    // -e: include if matches
                    result = matches;
                } else {
                    // -v: exclude if matches (include if doesn't match)
                    result = !matches;
                }
                
                // If current filter excludes this item, we're done
                if (!result) {
                    break;
                }
            } catch (const std::regex_error& e) {
                std::cerr << "Invalid regex pattern '" << filter.pattern << "': " << e.what() << std::endl;
                return false;
            }
        }
        
        return result;
    }
    
    CommentStyle get_comment_style(const fs::path& file_path) const {
        std::string extension = file_path.extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
        
        auto it = comment_styles.find(extension);
        if (it != comment_styles.end()) {
            return it->second;
        }
        
        // Track unknown extensions (only if they have an extension)
        if (!extension.empty() && extension != ".") {
            unknown_extensions.insert(extension);
        }
        
        // Default: no comments
        return {"", "", "", false};
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
        
        if (bytes_read == 0) {
            return false; // Empty file is considered text
        }
        
        // Check for null bytes (definitive indicator of binary files)
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            if (buffer[i] == '\0') {
                return true;
            }
        }
        
        // Check for high ratio of non-printable characters
        int non_printable = 0;
        for (std::streamsize i = 0; i < bytes_read; ++i) {
            unsigned char c = static_cast<unsigned char>(buffer[i]);
            // Allow common whitespace characters
            if (c < 32 && c != '\t' && c != '\n' && c != '\r') {
                non_printable++;
            }
            // Check for extended ASCII that might indicate binary
            if (c > 126) {
                non_printable++;
            }
        }
        
        // If more than 30% non-printable, consider it binary
        return (non_printable * 100 / bytes_read > 30);
    }
    
    void print_tree(const fs::path& dir, const std::string& prefix, std::vector<fs::path>& visible_files) const {
        if (!fs::exists(dir) || !fs::is_directory(dir)) {
            return;
        }
        
        std::vector<fs::directory_entry> entries;
        
        // Collect all entries
        try {
            for (const auto& entry : fs::directory_iterator(dir)) {
                // Skip hidden files (starting with .)
                std::string filename = entry.path().filename().string();
                if (filename[0] != '.' && matches_patterns(filename)) {
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
        
        // Print entries and collect visible files
        for (const auto& entry : entries) {
            std::string filename = entry.path().filename().string();
            std::cout << prefix << "|_ " << filename << std::endl;
            
            if (entry.is_directory()) {
                print_tree(entry.path(), prefix + "|     ", visible_files);
            } else if (entry.is_regular_file()) {
                visible_files.push_back(entry.path());
            }
        }
    }
    
    void print_file_content(const std::vector<fs::path>& visible_files, const std::string& root_name, const fs::path& base_dir) const {
        if (visible_files.empty()) {
            std::cout << std::endl << "No matching directories or files!" << std::endl;
            return;
        }
        
        // Sort files
        std::vector<fs::path> sorted_files = visible_files;
        std::sort(sorted_files.begin(), sorted_files.end());
        
        // Print file contents
        for (const auto& file_path : sorted_files) {
            if (is_binary(file_path)) {
                // Skip binary files, don't show content
                continue;
            }
            
            fs::path relative_path = fs::relative(file_path, base_dir);
            CommentStyle style = get_comment_style(file_path);
            
            std::cout << std::endl;
            
            if (style.has_comments && !style.single_line.empty()) {
                // Use single-line comments
                std::cout << style.single_line << " ========================================================" << std::endl;
                std::cout << style.single_line << "  File: " << root_name << "/" << relative_path.string() << std::endl;
                std::cout << style.single_line << "  <content> ----------------------------------------------" << std::endl;
            } else {
                // Fallback to original format for files without comments
                std::cout << "===================================" << std::endl;
                std::cout << "File: " << root_name << "/" << relative_path.string() << std::endl;
                std::cout << "<content> -------------------------" << std::endl;
            }
            
            std::ifstream file(file_path);
            if (file.is_open()) {
                std::cout << file.rdbuf();
                file.close();
            } else {
                std::cout << "Error: Could not open file" << std::endl;
            }
            
            if (style.has_comments && !style.single_line.empty()) {
                std::cout << style.single_line << "  </content> ----------------------------------------------" << std::endl;
            } else {
                std::cout << "</content> ------------------------" << std::endl;
            }
            std::cout << std::endl;
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
        CommentStyle style = get_comment_style(file_path);
        
        if (style.has_comments && !style.single_line.empty()) {
            // Use single-line comments
            std::cout << style.single_line << " ========================================================" << std::endl;
            std::cout << style.single_line << "  File: " << root_name << "/" << file_name << std::endl;
            std::cout << style.single_line << "  <content> ----------------------------------------------" << std::endl;
        } else {
            // Fallback to original format
            std::cout << "===================================" << std::endl;
            std::cout << "File: " << root_name << "/" << file_name << std::endl;
            std::cout << "<content> -------------------------" << std::endl;
        }
        
        std::ifstream file(file_path);
        if (file.is_open()) {
            std::cout << file.rdbuf();
            file.close();
        } else {
            std::cout << "Error: Could not open file" << std::endl;
        }
        
        if (style.has_comments && !style.single_line.empty()) {
            std::cout << style.single_line << "  </content> ----------------------------------------------" << std::endl;
        } else {
            std::cout << "</content> ------------------------" << std::endl;
        }
    }
    
    void print_unknown_extensions_warning() const {
        if (!unknown_extensions.empty()) {
            std::cerr << std::endl << "Warning: Unknown file extensions encountered (no comment style defined):" << std::endl;
            for (const auto& ext : unknown_extensions) {
                std::cerr << "  " << ext << std::endl;
            }
            std::cerr << "These files will use the default format without comment-style headers." << std::endl;
            std::cerr << std::endl;
        }
    }
    
public:
    void add_pattern_filter(const std::string& pattern, bool is_include) {
        pattern_filters.push_back({pattern, is_include});
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
            
            std::vector<fs::path> visible_files;
            print_tree(current_dir, "", visible_files);
            
            if (!show_dir_only) {
                print_file_content(visible_files, root_name, current_dir);
            }
            
            // Print warning about unknown extensions at the end
            print_unknown_extensions_warning();
        } else {
            fs::path target_path(target);
            
            if (fs::is_directory(target_path)) {
                std::string root_name = fs::absolute(target_path).filename().string();
                
                std::cout << root_name << std::endl;
                
                std::vector<fs::path> visible_files;
                print_tree(target_path, "", visible_files);
                
                if (!show_dir_only) {
                    print_file_content(visible_files, root_name, target_path);
                }
                
                // Print warning about unknown extensions at the end
                print_unknown_extensions_warning();
            } else if (fs::is_regular_file(target_path)) {
                std::string filename = target_path.filename().string();
                if (matches_patterns(filename)) {
                    print_single_file(target_path);
                    // Print warning about unknown extensions at the end
                    print_unknown_extensions_warning();
                } else {
                    std::cout << "No matching directories or files!" << std::endl;
                }
            } else {
                std::cout << "Error: Target does not exist or is not accessible." << std::endl;
            }
        }
    }
    
    static void print_usage(const char* program_name) {
        std::cout << "Usage: " << program_name << " [-d] [-e pattern] [-v pattern] [filename|directory]" << std::endl;
        std::cout << "  -d : only show the directory structure" << std::endl;
        std::cout << "  -e pattern : only include files/directories matching pattern (regex)" << std::endl;
        std::cout << "  -v pattern : exclude files/directories matching pattern (regex)" << std::endl;
        std::cout << "  Multiple -e and -v options can be used and are applied in order" << std::endl;
        std::cout << "  filename or directory : show output from given directory, or if a file, only the file content" << std::endl;
        std::cout << "  If no arguments are provided, it will show both structure and content for the current directory" << std::endl;
        std::cout << std::endl;
        std::cout << "Examples:" << std::endl;
        std::cout << "  " << program_name << " -v build -e \"\\\\.cpp$\"     # Exclude 'build' dirs, include only .cpp files" << std::endl;
        std::cout << "  " << program_name << " -e \"src|include\"          # Include only items matching 'src' or 'include'" << std::endl;
        std::cout << "  " << program_name << " -v \"\\\\.o$\" -v \"\\\\.so$\"     # Exclude .o and .so files" << std::endl;
    }
};

int main(int argc, char* argv[]) {
    TreePrinter printer;
    std::string target;
    
    int opt;
    while ((opt = getopt(argc, argv, "de:v:")) != -1) {
        switch (opt) {
            case 'd':
                printer.set_show_dir_only(true);
                break;
            case 'e':
                printer.add_pattern_filter(optarg, true);  // include pattern
                break;
            case 'v':
                printer.add_pattern_filter(optarg, false); // exclude pattern
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
